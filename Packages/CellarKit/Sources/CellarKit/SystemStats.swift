import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import IOKit.ps

/// A cheap reading of how the Mac and the running game are doing, for the overlay.
public struct SystemSample: Sendable, Equatable {
    public var date: Date
    /// Share of the whole Mac's CPU the game is using, 0...1.
    public var gameCPU: Double
    public var gameMemoryBytes: UInt64
    /// Share of the Mac's memory in use, 0...1.
    public var memoryUsed: Double
    public var thermal: ThermalLevel
    /// Battery charge 0...1, nil on a Mac without one.
    public var battery: Double?
    public var charging: Bool
    public var onBattery: Bool
    /// macOS's estimate, nil while it's still working one out or on power.
    public var batteryMinutesLeft: Int?
}

public enum ThermalLevel: Int, Sendable, Comparable {
    case normal, warm, hot, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .normal
        case .fair: self = .warm
        case .serious: self = .hot
        case .critical: self = .critical
        @unknown default: self = .normal
        }
    }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .warm: "Warm"
        case .hot: "Hot"
        case .critical: "Very hot"
        }
    }
}

/// Keeps the last CPU reading, since CPU use is a difference between two readings.
public final class SystemSampler: @unchecked Sendable {
    private var lastCPU: (date: Date, nanos: UInt64)?
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    public init() {}

    public func sample(gamePIDs: [pid_t]) -> SystemSample {
        let now = Date()
        var nanos: UInt64 = 0
        var memory: UInt64 = 0
        for pid in gamePIDs {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { continue }
            nanos += Self.nanoseconds(machUnits: info.ri_user_time + info.ri_system_time)
            memory += info.ri_phys_footprint
        }
        var cpu = 0.0
        if let last = lastCPU, nanos >= last.nanos {
            let elapsed = now.timeIntervalSince(last.date)
            if elapsed > 0 { cpu = min(1, Double(nanos - last.nanos) / 1e9 / elapsed / cores) }
        }
        lastCPU = (now, nanos)
        let power = Self.power()
        return SystemSample(date: now, gameCPU: cpu, gameMemoryBytes: memory, memoryUsed: Self.memoryUsed(),
                            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState), battery: power.level,
                            charging: power.charging, onBattery: power.onBattery, batteryMinutesLeft: power.minutesLeft)
    }

    /// `ri_*_time` is in Mach time units, which aren't nanoseconds on Apple silicon.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func nanoseconds(machUnits: UInt64) -> UInt64 {
        machUnits &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    private static func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // Same sum as Activity Monitor's "Memory Used": app memory, wired and compressed.
        let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let bytes = pages &* UInt64(sysconf(_SC_PAGESIZE))
        return min(1, Double(bytes) / Double(ProcessInfo.processInfo.physicalMemory))
    }

    private static func power() -> (level: Double?, charging: Bool, onBattery: Bool, minutesLeft: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false, false, nil)
        }
        for source in list {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = details[kIOPSCurrentCapacityKey] as? Int,
                  let max = details[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = details[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let minutes = details[kIOPSTimeToEmptyKey] as? Int
            return (Double(current) / Double(max), details[kIOPSIsChargingKey] as? Bool ?? false, onBattery,
                    onBattery && (minutes ?? -1) > 0 ? minutes : nil)
        }
        return (nil, false, false, nil)
    }
}

/// The Mac's output volume, so it can be changed from over a full-screen game.
public enum SystemVolume {
    private static var outputDevice: AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 0...1, or nil when the current output has no volume control (HDMI, for one).
    public static var level: Float? {
        get {
            guard let device = outputDevice else { return nil }
            var address = address
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value
        }
        set {
            guard let device = outputDevice, var value = newValue else { return }
            var address = address
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }
}
