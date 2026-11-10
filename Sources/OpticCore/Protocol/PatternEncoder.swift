import Foundation

/// OPTC-1 pattern profiles. `C52` is the first 52 modules of the same encoding.
public enum LayoutProfile: String, CaseIterable {
    case f68 = "F68"
    case c52 = "C52"

    public var moduleCount: Int {
        switch self {
        case .f68: return 68
        case .c52: return 52
        }
    }
}

/// 8-bit SDR code values. 0 maps to `low`, 1 maps to `high`.
public struct PatternLevels: Equatable {
    public var low: UInt8
    public var high: UInt8

    public init(low: UInt8, high: UInt8) {
        self.low = low
        self.high = high
    }

    public static let sdrDefault = PatternLevels(low: 32, high: 224)
}

/// Deterministic module bits for one dynamic state.
public struct PatternBits: Hashable {
    public let renderSeq: RenderSeq
    public let profile: LayoutProfile
    public let payloadN: UInt16
    public let gray: UInt16
    public let crc8: UInt8
    public let runnerIndex: UInt8
    /// One entry per protocol module, values 0 or 1.
    public let bits: [UInt8]

    public init(
        renderSeq: RenderSeq,
        profile: LayoutProfile,
        payloadN: UInt16,
        gray: UInt16,
        crc8: UInt8,
        runnerIndex: UInt8,
        bits: [UInt8]
    ) {
        self.renderSeq = renderSeq
        self.profile = profile
        self.payloadN = payloadN
        self.gray = gray
        self.crc8 = crc8
        self.runnerIndex = runnerIndex
        self.bits = bits
    }

    public func codes(_ levels: PatternLevels = .sdrDefault) -> [UInt8] {
        bits.map { bit in bit == 0 ? levels.low : levels.high }
    }
}

/// OPTC-1 encoding. Touches no UI, GPU or clock.
public enum PatternEncoder {
    /// Module 0–3 preamble: L, H, H, L.
    public static let preamble: [UInt8] = [0, 1, 1, 0]

    public static func payload(_ seq: RenderSeq) -> UInt16 {
        seq.payloadN
    }

    public static func gray16(_ payloadN: UInt16) -> UInt16 {
        payloadN ^ (payloadN >> 1)
    }

    /// CRC-8/SMBUS over the two payload bytes, low byte first.
    public static func crc8(_ payloadN: UInt16) -> UInt8 {
        crc8(bytes: [UInt8(payloadN & 0xFF), UInt8((payloadN >> 8) & 0xFF)])
    }

    /// width=8, poly=0x07, init=0, refin=false, refout=false, xorout=0.
    public static func crc8<S: Sequence>(bytes: S) -> UInt8 where S.Element == UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                if crc & 0x80 != 0 {
                    crc = (crc << 1) ^ 0x07
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    public static func runnerIndex(_ payloadN: UInt16) -> UInt8 {
        UInt8(payloadN % 8)
    }

    public static func encode(_ seq: RenderSeq, profile: LayoutProfile) -> PatternBits {
        let payloadN = seq.payloadN
        let gray = gray16(payloadN)
        let crc = crc8(payloadN)
        let runner = runnerIndex(payloadN)

        var bits: [UInt8] = []
        bits.reserveCapacity(profile.moduleCount)
        bits.append(contentsOf: preamble)

        // Gray MSB first, each bit followed by its complement (0 -> [L,H]).
        for shift in stride(from: 15, through: 0, by: -1) {
            let bit = UInt8((gray >> UInt16(shift)) & 1)
            bits.append(bit)
            bits.append(1 - bit)
        }

        // CRC MSB first, complement encoded as well.
        for shift in stride(from: 7, through: 0, by: -1) {
            let bit = (crc >> UInt8(shift)) & 1
            bits.append(bit)
            bits.append(1 - bit)
        }

        if profile == .f68 {
            for index in 0..<8 {
                let bit: UInt8 = UInt8(index) == runner ? 1 : 0
                bits.append(bit)
                bits.append(1 - bit)
            }
        }

        return PatternBits(
            renderSeq: seq,
            profile: profile,
            payloadN: payloadN,
            gray: gray,
            crc8: crc,
            runnerIndex: runner,
            bits: bits
        )
    }
}
