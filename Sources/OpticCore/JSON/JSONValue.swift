import Foundation

/// A JSON object with contract-exact key names.
public typealias JSONObject = [String: JSONValue]

/// Minimal JSON value used for every exported document and for opaque
/// calibration models. It keeps 64-bit integers exact (no Double round trip),
/// keeps explicit `null`, and serialises with sorted keys so exported files are
/// byte-stable.
///
/// `Any` never appears in the public API; the only opaque place is
/// `ImportedCalibrationProfile.model`, which the display app must not interpret.
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public func serialized() throws -> String {
        var out = ""
        try append(to: &out, depth: 0)
        return out
    }

    private func append(to out: inout String, depth: Int) throws {
        guard depth < 128 else { throw JSONError.tooDeep }
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .double(let value):
            guard value.isFinite else { throw JSONError.nonFiniteNumber }
            out += JSONValue.text(for: value)
        case .string(let value):
            out += JSONValue.quoted(value)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                try value.append(to: &out, depth: depth + 1)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                out += JSONValue.quoted(key)
                out += ":"
                try members[key, default: .null].append(to: &out, depth: depth + 1)
            }
            out += "}"
        }
    }

    static func text(for value: Double) -> String {
        // Keep integral values readable ("120" instead of "120.0") while the
        // JSON type stays a number, which the contract allows for "数值".
        if value == value.rounded(), abs(value) < 9.0e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - Accessors

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: JSONObject? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

public enum JSONError: Error, Equatable {
    case unexpectedEnd
    case unexpectedCharacter(UInt8)
    case invalidLiteral
    case invalidNumber
    case invalidEscape
    case invalidUnicode
    case invalidUTF8
    case trailingData
    case tooDeep
    case nonFiniteNumber
}

/// Strict RFC 8259 parser. It exists so the core can read the protocol test
/// vectors and calibration models without turning integers into doubles and
/// without the `NSNumber` boolean ambiguity of `JSONSerialization`.
public enum JSONParser {
    public static func parse(_ data: Data) throws -> JSONValue {
        var scanner = Scanner(bytes: Array(data))
        let value = try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { throw JSONError.trailingData }
        return value
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        var isAtEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard index < bytes.count else { throw JSONError.unexpectedEnd }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func parseObject() throws -> JSONValue {
            depth += 1
            guard depth < 128 else { throw JSONError.tooDeep }
            defer { depth -= 1 }
            index += 1
            var members: JSONObject = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                    throw JSONError.unexpectedCharacter(index < bytes.count ? bytes[index] : 0)
                }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    throw JSONError.unexpectedCharacter(index < bytes.count ? bytes[index] : 0)
                }
                index += 1
                members[key] = try parseValue()
                skipWhitespace()
                guard index < bytes.count else { throw JSONError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                }
                throw JSONError.unexpectedCharacter(bytes[index])
            }
        }

        mutating func parseArray() throws -> JSONValue {
            depth += 1
            guard depth < 128 else { throw JSONError.tooDeep }
            defer { depth -= 1 }
            index += 1
            var values: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            while true {
                values.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw JSONError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(values)
                }
                throw JSONError.unexpectedCharacter(bytes[index])
            }
        }

        mutating func parseString() throws -> String {
            index += 1 // opening quote
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw JSONError.unexpectedEnd }
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") { break }
                if byte == UInt8(ascii: "\\") {
                    guard index < bytes.count else { throw JSONError.unexpectedEnd }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                    case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                    case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        let scalar = try parseUnicodeScalar()
                        out.append(contentsOf: String(scalar).utf8)
                    default:
                        throw JSONError.invalidEscape
                    }
                } else {
                    out.append(byte)
                }
            }
            guard let string = String(bytes: out, encoding: .utf8) else { throw JSONError.invalidUTF8 }
            return string
        }

        mutating func parseUnicodeScalar() throws -> Unicode.Scalar {
            let first = try parseHex4()
            if first >= 0xD800, first <= 0xDBFF {
                guard index + 1 < bytes.count,
                      bytes[index] == UInt8(ascii: "\\"),
                      bytes[index + 1] == UInt8(ascii: "u")
                else { throw JSONError.invalidUnicode }
                index += 2
                let second = try parseHex4()
                guard second >= 0xDC00, second <= 0xDFFF else { throw JSONError.invalidUnicode }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let scalar = Unicode.Scalar(UInt32(combined)) else { throw JSONError.invalidUnicode }
                return scalar
            }
            guard let scalar = Unicode.Scalar(UInt32(first)) else { throw JSONError.invalidUnicode }
            return scalar
        }

        mutating func parseHex4() throws -> Int {
            guard index + 4 <= bytes.count else { throw JSONError.unexpectedEnd }
            var value = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                index += 1
                let digit: Int
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = Int(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = Int(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = Int(byte - UInt8(ascii: "A")) + 10
                default: throw JSONError.invalidUnicode
                }
                value = value * 16 + digit
            }
            return value
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            var sawDigit = false
            var digitCount = 0
            let firstDigitIndex = index
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
                sawDigit = true
                digitCount += 1
            }
            guard sawDigit else { throw JSONError.invalidNumber }
            // RFC 8259 forbids leading zeros, and OPTC-1 decimal strings forbid
            // them too; rejecting them here keeps both readings aligned.
            if digitCount > 1, bytes[firstDigitIndex] == UInt8(ascii: "0") {
                throw JSONError.invalidNumber
            }
            var isFloat = false
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isFloat = true
                index += 1
                var fractionDigit = false
                while index < bytes.count, isDigit(bytes[index]) {
                    index += 1
                    fractionDigit = true
                }
                guard fractionDigit else { throw JSONError.invalidNumber }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isFloat = true
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                var exponentDigit = false
                while index < bytes.count, isDigit(bytes[index]) {
                    index += 1
                    exponentDigit = true
                }
                guard exponentDigit else { throw JSONError.invalidNumber }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if !isFloat, let integer = Int64(text) { return .int(integer) }
            if let double = Double(text), double.isFinite { return .double(double) }
            throw JSONError.invalidNumber
        }

        func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw JSONError.invalidLiteral }
                index += 1
            }
        }
    }
}
