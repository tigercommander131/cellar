import Foundation
import IOKit.ps

/// What Cellar needs from the Mac before setup can run.
public struct HostCheck: Sendable {
    public var rosettaInstalled: Bool
    public var physicalMemory: UInt64
    public var availableDiskBytes: Int64
    public var macOSVersion: OperatingSystemVersion
    public var isAppleSilicon: Bool

    public static let rosettaRuntime = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"
    /// Engine, graphics packs, Steam and a small game; big games need far more.
    public static let minimumSetupBytes: Int64 = 10 * 1_000_000_000

    public static func current(volume: URL = CellarPaths.defaultRoot) -> HostCheck {
        HostCheck(
            rosettaInstalled: FileManager.default.fileExists(atPath: rosettaRuntime),
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            availableDiskBytes: availableBytes(near: volume),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
            isAppleSilicon: isArm64()
        )
    }

    /// True while the Mac is running on its battery.
    public static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPSBatteryPowerValue
    }

    public var memoryGB: Int { Int((Double(physicalMemory) / 1_073_741_824).rounded()) }

    public var hasRoomForSetup: Bool { availableDiskBytes >= Self.minimumSetupBytes }

    public var problems: [String] {
        var list: [String] = []
        if !isAppleSilicon { list.append("Cellar needs a Mac with Apple silicon.") }
        if macOSVersion.majorVersion < 26 { list.append("Cellar needs macOS 26 or later.") }
        if !rosettaInstalled { list.append("Rosetta 2 isn't installed.") }
        if !hasRoomForSetup {
            list.append("Setup needs at least \(Self.minimumSetupBytes / 1_000_000_000) GB free; this Mac has \(availableDiskBytes / 1_000_000_000) GB.")
        }
        return list
    }

    static func availableBytes(near url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func isArm64() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // hw.optional.arm64 is 1 on Apple silicon, even when this process runs under Rosetta.
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Installs Rosetta 2. Needs no password when run by an admin user from a GUI app.
    public static func installRosetta() throws {
        let result = try Shell.run("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"])
        guard result.status == 0 else { throw CellarError("Rosetta install failed: \(result.output)") }
    }
}
