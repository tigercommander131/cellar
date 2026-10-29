import Foundation

public struct CellarError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Small helpers for running short-lived macOS tools (tar, xattr, codesign...).
/// Wine itself goes through `WineRunner`, which logs to files instead.
enum Shell {
    struct Result: Sendable {
        var status: Int32
        var output: String
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil,
                    currentDirectory: URL? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func check(_ tool: String, _ arguments: [String]) throws {
        let result = try run(tool, arguments)
        guard result.status == 0 else {
            throw CellarError("\((tool as NSString).lastPathComponent) failed (\(result.status)): \(result.output.suffix(500))")
        }
    }
}
