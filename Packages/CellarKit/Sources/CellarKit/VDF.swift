import Foundation

/// Valve's text KeyValues format (`.vdf`, `.acf`): nested `"key" "value"` and `"key" { ... }`.
public indirect enum VDF: Sendable, Equatable {
    case string(String)
    case object([(String, VDF)])

    public static func == (lhs: VDF, rhs: VDF) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public subscript(key: String) -> VDF? {
        guard case .object(let pairs) = self else { return nil }
        // Valve treats keys case-insensitively.
        return pairs.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var pairs: [(String, VDF)] {
        if case .object(let p) = self { return p }
        return []
    }

    public static func parse(_ text: String) throws -> VDF {
        var parser = Parser(chars: Array(text.unicodeScalars))
        return .object(try parser.parseObject(topLevel: true))
    }

    public static func parse(contentsOf url: URL) throws -> VDF {
        let data = try Data(contentsOf: url)
        return try parse(String(decoding: data, as: UTF8.self))
    }

    struct Parser {
        let chars: [Unicode.Scalar]
        var i = 0

        init(chars: [Unicode.Scalar]) { self.chars = chars }

        mutating func skipTrivia() {
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{FEFF}" {
                    i += 1
                } else if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                } else {
                    return
                }
            }
        }

        mutating func token() throws -> String? {
            skipTrivia()
            guard i < chars.count else { return nil }
            if chars[i] == "\"" {
                i += 1
                var out = String.UnicodeScalarView()
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        default: out.append(chars[i])
                        }
                    } else {
                        out.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { throw CellarError("Unterminated string in VDF.") }
                i += 1
                return String(out)
            }
            var out = String.UnicodeScalarView()
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "{" || c == "}" || c == "\"" { break }
                out.append(c)
                i += 1
            }
            return String(out)
        }

        mutating func parseObject(topLevel: Bool) throws -> [(String, VDF)] {
            var pairs: [(String, VDF)] = []
            while true {
                skipTrivia()
                guard i < chars.count else {
                    if topLevel { return pairs }
                    throw CellarError("Unexpected end of VDF.")
                }
                if chars[i] == "}" {
                    guard !topLevel else { throw CellarError("Unexpected } in VDF.") }
                    i += 1
                    return pairs
                }
                guard let key = try token() else { return pairs }
                skipTrivia()
                guard i < chars.count else { throw CellarError("Missing value for \(key) in VDF.") }
                if chars[i] == "{" {
                    i += 1
                    pairs.append((key, .object(try parseObject(topLevel: false))))
                } else if let value = try token() {
                    pairs.append((key, .string(value)))
                }
                // Skip conditionals like [$WIN32].
                skipTrivia()
                if i < chars.count, chars[i] == "[" {
                    while i < chars.count, chars[i] != "]" { i += 1 }
                    i += 1
                }
            }
        }
    }
}
