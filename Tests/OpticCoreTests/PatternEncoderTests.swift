import XCTest
@testable import OpticCore

final class PatternEncoderTests: XCTestCase {
    // Fixture provenance: copied byte-for-byte from
    // /Users/dengqi/Downloads/optical_sync_design/validation/protocol_test_vectors.json
    // SHA-256 cfe36b72a606edee18315b9eb841910bacade176b491e80b15a32b61dc2742a9
    func testDeliveryVectorsMatchExactly() throws {
        let document = try TestFixtures.vectors()
        XCTAssertEqual(document["protocol"]?.stringValue, "OPTC-1")
        XCTAssertEqual(document["layout"]?.stringValue, "F68")
        let vectors = try XCTUnwrap(document["vectors"]?.arrayValue)
        XCTAssertEqual(vectors.count, 14)
        // The vectors are the external oracle; the encoder is never used to
        // generate its own expectations.
        for vector in vectors {
            let renderSeqValue = try XCTUnwrap(vector["render_seq"]?.intValue)
            let seq = RenderSeq(UInt64(renderSeqValue))
            let payloadN = try XCTUnwrap(vector["payload_n"]?.intValue)
            let expectedCRC = try XCTUnwrap(UInt8(vector["crc_hex"]?.stringValue ?? "", radix: 16))
            let expectedRunner = try XCTUnwrap(vector["runner_index"]?.intValue)
            let expectedCodes = try XCTUnwrap(vector["module_codes"]?.arrayValue).compactMap { $0.intValue.map(UInt8.init) }
            let expectedBitString = try XCTUnwrap(vector["modules_01"]?.stringValue)

            let bits = PatternEncoder.encode(seq, profile: .f68)
            XCTAssertEqual(Int64(bits.payloadN), payloadN, "payload_n for \(seq)")
            XCTAssertEqual(bits.crc8, expectedCRC, "crc8 for \(seq)")
            XCTAssertEqual(Int64(bits.runnerIndex), expectedRunner, "runner for \(seq)")
            XCTAssertEqual(bits.bits.map(String.init).joined(), expectedBitString, "modules_01 for \(seq)")
            XCTAssertEqual(bits.codes(), expectedCodes, "module codes for \(seq)")
            XCTAssertEqual(bits.bits.count, 68)

            let c52 = PatternEncoder.encode(seq, profile: .c52)
            XCTAssertEqual(c52.bits, Array(bits.bits.prefix(52)))
            XCTAssertEqual(c52.crc8, expectedCRC)
            XCTAssertEqual(c52.payloadN, bits.payloadN)
        }
    }

    func testThirtyTwoBitBoundaryVectors() throws {
        let document = try TestFixtures.vectors()
        let vectors = try XCTUnwrap(document["vectors"]?.arrayValue)
        let bySeq = Dictionary(uniqueKeysWithValues: vectors.compactMap { vector -> (UInt64, JSONValue)? in
            guard let value = vector["render_seq"]?.intValue else { return nil }
            return (UInt64(value), vector)
        })
        // 65536 must encode the same payload as 0 but stay a different state.
        let zero = PatternEncoder.encode(RenderSeq(0), profile: .f68)
        let low = PatternEncoder.encode(RenderSeq(65_536), profile: .f68)
        XCTAssertEqual(low.payloadN, 0)
        XCTAssertEqual(low.bits, zero.bits)
        XCTAssertEqual(low.renderSeq.rawValue, 65_536)
        XCTAssertEqual(bySeq[65_536]?["payload_n"]?.intValue, 0)
        XCTAssertEqual(bySeq[65_537]?["payload_n"]?.intValue, 1)
    }

    func testCRCCheckValueFromStandard() {
        // CRC-8/SMBUS check value for "123456789" is 0xF4; the vector file also
        // records it. This is independent of any pattern.
        XCTAssertEqual(PatternEncoder.crc8(bytes: Array("123456789".utf8)), 0xF4)
        XCTAssertEqual(PatternEncoder.crc8(0), 0x00)
        XCTAssertEqual(PatternEncoder.crc8(1), 0x15)
        XCTAssertEqual(PatternEncoder.crc8(2), 0x2A)
        XCTAssertEqual(PatternEncoder.crc8(3), 0x3F)
    }

    func testCRCInputByteOrderIsLowThenHigh() {
        for payload in [UInt16(0), 1, 255, 256, 0x1234, 0xFFFF] {
            let bytes = [UInt8(payload & 0xFF), UInt8(payload >> 8)]
            XCTAssertEqual(PatternEncoder.crc8(payload), PatternEncoder.crc8(bytes: bytes))
        }
        XCTAssertNotEqual(PatternEncoder.crc8(0x1234), PatternEncoder.crc8(bytes: [0x12, 0x34]))
    }

    func testAllPayloadsHaveContractProperties() {
        // Exhaustive over the 16-bit payload space, from the protocol rules:
        // Gray is a bijection, every bit is followed by its complement, the
        // preamble is fixed, and Runner has exactly one logical one.
        var seenGray: Set<UInt16> = []
        for value in 0...Int(UInt16.max) {
            let payload = UInt16(value)
            let gray = PatternEncoder.gray16(payload)
            seenGray.insert(gray)
            var inverse = gray
            inverse ^= inverse >> 1
            inverse ^= inverse >> 2
            inverse ^= inverse >> 4
            inverse ^= inverse >> 8
            XCTAssertEqual(inverse, payload)

            let bits = PatternEncoder.encode(RenderSeq(UInt64(payload)), profile: .f68).bits
            XCTAssertEqual(Array(bits[0..<4]), PatternEncoder.preamble)
            var index = 4
            while index < 68 {
                XCTAssertNotEqual(bits[index], bits[index + 1], "complement pair at \(index) for \(payload)")
                index += 2
            }
            // Runner is modules 52...67, one logical one.
            let runnerBits = stride(from: 52, to: 68, by: 2).map { bits[$0] }
            XCTAssertEqual(runnerBits.filter { $0 == 1 }.count, 1, "runner for \(payload)")
            XCTAssertEqual(runnerBits.firstIndex(of: 1).map(UInt8.init), PatternEncoder.runnerIndex(payload))
        }
        XCTAssertEqual(seenGray.count, 65_536)
    }

    func testUnsigned64BoundarySerialization() throws {
        let maximum = RenderSeq(UInt64.max)
        XCTAssertEqual(maximum.description, "18446744073709551615")
        XCTAssertEqual(maximum.payloadN, 65_535)
        XCTAssertThrowsError(try maximum.successor()) { error in
            XCTAssertEqual(error as? RenderSeqError, .exhausted)
        }
        XCTAssertEqual(try RenderSeq(decimalString: "18446744073709551615"), maximum)
        XCTAssertEqual(try RenderSeq(decimalString: "0"), .zero)
        XCTAssertEqual(RenderSeq(65_536).description, "65536")
        XCTAssertEqual(PatternEncoder.encode(maximum, profile: .f68).payloadN, 65_535)

        XCTAssertThrowsError(try RenderSeq(decimalString: "0001"))
        XCTAssertThrowsError(try RenderSeq(decimalString: "-1"))
        XCTAssertThrowsError(try RenderSeq(decimalString: ""))
        XCTAssertThrowsError(try RenderSeq(decimalString: "18446744073709551616"))
        XCTAssertThrowsError(try RenderSeq(decimalString: "1.5"))
    }

    func testC52IsAStrictPrefixAndKeepsCRC() {
        for value in [UInt64(0), 1, 7, 255, 65_535, 65_536, UInt64.max] {
            let seq = RenderSeq(value)
            let f68 = PatternEncoder.encode(seq, profile: .f68)
            let c52 = PatternEncoder.encode(seq, profile: .c52)
            XCTAssertEqual(c52.bits.count, 52)
            XCTAssertEqual(f68.bits.count, 68)
            XCTAssertEqual(c52.bits, Array(f68.bits.prefix(52)))
            XCTAssertEqual(c52.gray, f68.gray)
            XCTAssertEqual(c52.crc8, f68.crc8)
            XCTAssertEqual(c52.runnerIndex, f68.runnerIndex)
        }
    }
}
