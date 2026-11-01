import Darwin
import Foundation

/// A running process that belongs to one of Cellar's Wine engines.
public struct WineProcess: Sendable, Equatable {
    public var pid: pid_t
    /// The Windows program's file name, e.g. `steam.exe`, from the process's first argument.
    public var windowsName: String
    /// The first argument in full, usually the program's Windows path.
    public var windowsPath: String
    public var executable: String
}

public enum ProcessSnapshot {
    /// Wine processes of Cellar's engines. Some run from the packs folder, but CrossOver's loader
    /// links (and Cellar's game bundles) put the binary in a `winetemp-` folder under the user's
    /// temp directory. Each of those folders holds an `ntdll.so` link back to its engine, which
    /// tells ours apart from another Wine app's. (Wine overwrites its argv and environment, so
    /// those can't be used for this.)
    public static func wineProcesses(paths: CellarPaths) -> [WineProcess] {
        let packs = paths.packs.standardizedFileURL.resolvingSymlinksInPath().path
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [WineProcess] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(cString: buffer)
            guard path.hasPrefix(packs) || engineOwning(path).hasPrefix(packs) else { continue }
            let first = arguments(of: pid).first ?? path
            let name = first.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? first
            result.append(WineProcess(pid: pid, windowsName: name, windowsPath: first, executable: path))
        }
        return result
    }

    /// The engine folder a `winetemp-` loader link belongs to, or "" for anything else.
    static func engineOwning(_ executable: String) -> String {
        guard executable.contains("/winetemp-") else { return "" }
        let link = URL(fileURLWithPath: executable).deletingLastPathComponent().appending(path: "ntdll.so")
        return link.resolvingSymlinksInPath().path
    }

    /// argv of another process of the same user, via `KERN_PROCARGS2`.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, data[i] != 0 { i += 1 }   // executable path
        while i < size, data[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, data[i] != 0 { i += 1 }
            args.append(String(decoding: data[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
