import Darwin
import Foundation

/// A running process that belongs to one of Cellar's Wine engines.
public struct WineProcess: Sendable, Equatable {
    public var pid: pid_t
    /// The Windows program, e.g. `steam.exe`, from the process's first argument.
    public var windowsName: String
    public var executable: String
}

public enum ProcessSnapshot {
    /// Every process whose binary lives under `root` (our packs folder).
    public static func wineProcesses(under root: URL) -> [WineProcess] {
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path
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
            guard path.hasPrefix(prefix) else { continue }
            let args = arguments(of: pid)
            let first = args.first ?? path
            let name = first.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? first
            result.append(WineProcess(pid: pid, windowsName: name, executable: path))
        }
        return result
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
