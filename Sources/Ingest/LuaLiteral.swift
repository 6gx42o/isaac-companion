import Foundation

public indirect enum LuaValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case table(LuaTable)

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var numberValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var tableValue: LuaTable? { if case .table(let t) = self { t } else { nil } }
}

public struct LuaTable: Sendable, Equatable {
    public var array: [LuaValue] = []
    public var dict: [String: LuaValue] = [:]
    public subscript(key: String) -> LuaValue? { dict[key] }
    public init(array: [LuaValue] = [], dict: [String: LuaValue] = [:]) {
        self.array = array; self.dict = dict
    }
}

public enum LuaParseError: Error, CustomStringConvertible {
    case targetNotFound(String)
    case unexpected(String, at: Int)

    public var description: String {
        switch self {
        case .targetNotFound(let t): "assignment target not found: \(t)"
        case .unexpected(let m, let i): "unexpected \(m) at offset \(i)"
        }
    }
}

/// Reads Lua *table literals*. Not a Lua implementation -- just enough to load
/// EID's four data files.
///
/// A regex will not do this job: keys are concat expressions (`[C_ID .. 2]`),
/// values nest (`LuckChance = { ... }`), and the description strings contain
/// escaped quotes, `#` markers and unicode arrows.
public struct LuaLiteralParser {
    private let chars: [Character]
    private var i = 0
    /// `local C_ID = "5.100."` and friends, so `[C_ID .. 2]` can resolve to "5.100.2".
    private var locals: [String: String] = [:]

    public init(_ source: String) {
        chars = Array(source)
        locals = Self.scanLocals(source)
    }

    private static func scanLocals(_ source: String) -> [String: String] {
        let re = try! NSRegularExpression(pattern: #"local\s+(\w+)\s*=\s*"([^"]*)""#)
        let range = NSRange(source.startIndex..., in: source)
        var out: [String: String] = [:]
        for m in re.matches(in: source, range: range) {
            guard let k = Range(m.range(at: 1), in: source),
                  let v = Range(m.range(at: 2), in: source) else { continue }
            out[String(source[k])] = String(source[v])
        }
        return out
    }

    /// Parses the table literal assigned to `target`, e.g. "EID.ItemData".
    public mutating func table(assignedTo target: String) throws -> LuaTable {
        guard let start = find(target) else { throw LuaParseError.targetNotFound(target) }
        i = start + Array(target).count
        skipTrivia()
        guard peek() == "=" else { throw LuaParseError.unexpected("missing '='", at: i) }
        i += 1
        skipTrivia()
        guard peek() == "{" else { throw LuaParseError.unexpected("missing '{'", at: i) }
        return try parseTable()
    }

    private func find(_ needle: String) -> Int? {
        let n = Array(needle)
        guard !n.isEmpty, chars.count >= n.count else { return nil }
        for start in 0...(chars.count - n.count) where Array(chars[start..<start + n.count]) == n {
            return start
        }
        return nil
    }

    // MARK: - scanning

    private func peek(_ offset: Int = 0) -> Character? {
        let j = i + offset
        return j < chars.count ? chars[j] : nil
    }

    private mutating func skipTrivia() {
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "-", peek(1) == "-" {
                i += 2
                // `--[[ ... ]]` block comment, else run to end of line.
                if peek() == "[", peek(1) == "[" {
                    i += 2
                    while i < chars.count, !(chars[i] == "]" && peek(1) == "]") { i += 1 }
                    i = min(i + 2, chars.count)
                } else {
                    // `isNewline`, not `!= "\n"`: EID's files are a mix of LF and
                    // CRLF, and Swift treats "\r\n" as ONE Character, so comparing
                    // against "\n" never matches and the skip eats the whole file.
                    while i < chars.count, !chars[i].isNewline { i += 1 }
                }
                continue
            }
            break
        }
    }

    private mutating func parseString() throws -> String {
        guard let quote = peek(), quote == "\"" || quote == "'" else {
            throw LuaParseError.unexpected("string", at: i)
        }
        i += 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 1
                guard i < chars.count else { break }
                switch chars[i] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(chars[i])
                }
                i += 1
                continue
            }
            if c == quote { i += 1; return out }
            out.append(c)
            i += 1
        }
        throw LuaParseError.unexpected("unterminated string", at: i)
    }

    private mutating func parseNumber() throws -> Double {
        let start = i
        if peek() == "-" || peek() == "+" { i += 1 }
        while let c = peek(), c.isNumber || c == "." || c == "e" || c == "E"
            || ((c == "-" || c == "+") && (chars[i - 1] == "e" || chars[i - 1] == "E")) {
            i += 1
        }
        guard let n = Double(String(chars[start..<i])) else {
            throw LuaParseError.unexpected("number", at: start)
        }
        return n
    }

    /// EID writes literal fractions (`Multiplier = 1/3`). Evaluated left to right,
    /// which is all these data files ever need -- no precedence, no parentheses.
    /// Deliberately does not skip newlines or comments, so a `-` on a following
    /// line is never mistaken for subtraction.
    private mutating func parseArithmeticTail(_ lhs: Double) -> Double {
        var value = lhs
        while true {
            let save = i
            while let c = peek(), c == " " || c == "\t" { i += 1 }
            guard let op = peek(), "*/+-".contains(op), !(op == "-" && peek(1) == "-") else {
                i = save
                return value
            }
            i += 1
            while let c = peek(), c == " " || c == "\t" { i += 1 }
            guard let c = peek(), c.isNumber || c == "-" || c == "+",
                  let rhs = try? parseNumber() else {
                i = save
                return value
            }
            _ = c
            switch op {
            case "*": value *= rhs
            case "/": value /= rhs
            case "+": value += rhs
            default: value -= rhs
            }
        }
    }

    private mutating func parseIdentifier() -> String {
        let start = i
        while let c = peek(), c.isLetter || c.isNumber || c == "_" { i += 1 }
        return String(chars[start..<i])
    }

    /// Lua renders an integral number without a decimal point when concatenating,
    /// so `"5.100." .. 2` is "5.100.2", not "5.100.2.0".
    private static func luaString(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
    }

    /// A bracketed key: `["5.100.8"]`, `[169]`, or `[C_ID .. 2]`.
    private mutating func parseBracketKey() throws -> String {
        i += 1  // consume '['
        var parts: [String] = []
        while true {
            skipTrivia()
            guard let c = peek() else { throw LuaParseError.unexpected("key", at: i) }
            if c == "]" { i += 1; break }
            if c == "\"" || c == "'" {
                parts.append(try parseString())
            } else if c.isNumber || c == "-" {
                parts.append(Self.luaString(try parseNumber()))
            } else if c == "." {
                i += 1  // part of the `..` concat operator
            } else if c.isLetter || c == "_" {
                let ident = parseIdentifier()
                parts.append(locals[ident] ?? ident)
            } else {
                throw LuaParseError.unexpected("key char '\(c)'", at: i)
            }
        }
        return parts.joined()
    }

    private mutating func parseValue() throws -> LuaValue {
        skipTrivia()
        guard let c = peek() else { throw LuaParseError.unexpected("value", at: i) }
        switch c {
        case "{": return .table(try parseTable())
        case "\"", "'": return .string(try parseString())
        default: break
        }
        if c.isNumber || c == "-" || c == "+" {
            return .number(parseArithmeticTail(try parseNumber()))
        }
        let ident = parseIdentifier()
        switch ident {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "nil": return .null
        case "":
            throw LuaParseError.unexpected("value char '\(c)'", at: i)
        default:
            // A reference to something we don't evaluate (a function, an enum).
            // Keep the name rather than failing the whole file.
            return .string(ident)
        }
    }

    private mutating func parseTable() throws -> LuaTable {
        guard peek() == "{" else { throw LuaParseError.unexpected("table", at: i) }
        i += 1
        var table = LuaTable()
        while true {
            skipTrivia()
            guard let c = peek() else { throw LuaParseError.unexpected("unterminated table", at: i) }
            if c == "}" { i += 1; return table }
            if c == "," || c == ";" { i += 1; continue }

            if c == "[" {
                let key = try parseBracketKey()
                skipTrivia()
                guard peek() == "=" else { throw LuaParseError.unexpected("'=' after key", at: i) }
                i += 1
                table.dict[key] = try parseValue()
                continue
            }

            // A bare `name = value` key, distinguished from an array element by
            // looking ahead for the '='.
            if c.isLetter || c == "_" {
                let save = i
                let ident = parseIdentifier()
                skipTrivia()
                if peek() == "=" && peek(1) != "=" {
                    i += 1
                    table.dict[ident] = try parseValue()
                    continue
                }
                i = save
            }
            table.array.append(try parseValue())
        }
    }
}
