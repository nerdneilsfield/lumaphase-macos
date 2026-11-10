import Foundation

/// Session-scoped identity of one dynamic encoding state (OPTC-1 `render_seq`).
///
/// It is an unsigned 64-bit counter, never a time. JSON uses its canonical
/// decimal string; `Double` is never involved.
public struct RenderSeq: Hashable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Strict decimal parsing: `"0"` or a digit string without leading zeros.
    public init(decimalString: String) throws {
        guard !decimalString.isEmpty else { throw RenderSeqError.invalidDecimalString(decimalString) }
        if decimalString.count > 1, decimalString.first == "0" {
            throw RenderSeqError.invalidDecimalString(decimalString)
        }
        for character in decimalString where !character.isASCII || !character.isNumber {
            throw RenderSeqError.invalidDecimalString(decimalString)
        }
        guard let value = UInt64(decimalString) else {
            throw RenderSeqError.invalidDecimalString(decimalString)
        }
        self.rawValue = value
    }

    public static let zero = RenderSeq(0)

    public static func < (lhs: RenderSeq, rhs: RenderSeq) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        String(rawValue)
    }

    /// The 16-bit payload displayed by the pattern.
    public var payloadN: UInt16 {
        UInt16(truncatingIfNeeded: rawValue)
    }

    /// Contract: a session never wraps back to zero. Hitting `UInt64.max` ends
    /// the session instead.
    public func successor() throws -> RenderSeq {
        guard rawValue < UInt64.max else { throw RenderSeqError.exhausted }
        return RenderSeq(rawValue + 1)
    }
}

public enum RenderSeqError: Error, Equatable {
    case invalidDecimalString(String)
    case exhausted
}
