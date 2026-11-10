import XCTest
@testable import OpticCore

final class JSONTests: XCTestCase {
    func testRoundTripPreservesIntegersAndEscapes() throws {
        let original: JSONValue = .object([
            "big": .int(Int64.max),
            "small": .int(Int64.min),
            "negative": .int(-1),
            "real": .double(59.94),
            "text": .string("a\"b\\c\nd\te\u{1}"),
            "unicode": .string("光学时间码"),
            "nothing": .null,
            "flag": .bool(false),
            "list": .array([.int(0), .string("1"), .null]),
            "nested": .object(["z": .int(2), "a": .int(1)])
        ])
        let parsed = try JSONParser.parse(original.serialized())
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(parsed["big"]?.intValue, Int64.max)
        XCTAssertEqual(parsed["small"]?.intValue, Int64.min)
        XCTAssertEqual(parsed["text"]?.stringValue, "a\"b\\c\nd\te\u{1}")
    }

    func testSerialisedObjectUsesSortedKeysAndNoSpaces() throws {
        let text = try JSONValue.object(["b": .int(1), "a": .int(2)]).serialized()
        XCTAssertEqual(text, "{\"a\":2,\"b\":1}")
    }

    func testNonFiniteNumbersAreRejected() {
        XCTAssertThrowsError(try JSONValue.double(.infinity).serialized()) { error in
            XCTAssertEqual(error as? JSONError, .nonFiniteNumber)
        }
        XCTAssertThrowsError(try JSONValue.double(.nan).serialized())
    }

    func testRejectsMalformedInput() {
        XCTAssertThrowsError(try JSONParser.parse("{\"a\":}"))
        XCTAssertThrowsError(try JSONParser.parse("[1,]"))
        XCTAssertThrowsError(try JSONParser.parse("{\"a\":1} trailing"))
        XCTAssertThrowsError(try JSONParser.parse("\"unterminated"))
        XCTAssertThrowsError(try JSONParser.parse("01"))
        XCTAssertThrowsError(try JSONParser.parse("1."))
        XCTAssertThrowsError(try JSONParser.parse("\"\\uD800\""))
    }

    func testIntegerNativeValuesInNanosecondsTravelAsStrings() throws {
        // Contract §6.2: native integer values are decimal strings.
        let sample = FieldSample.valid(rawNanoseconds: 1_234_567_890,
                                       nativeValue: .int(1_234_567_890),
                                       api: "CLOCK_UPTIME_RAW",
                                       nativeUnit: .nanoseconds)
        XCTAssertEqual(sample.nativeValue, .string("1234567890"))
        let entry = sample.jsonEntry()
        XCTAssertEqual(entry["native_value"]?.stringValue, "1234567890")
        XCTAssertEqual(entry["native_unit"]?.stringValue, "NS")

        let seconds = FieldSample.validSeconds(1.5, api: "MTLDrawable.presentedTime")
        XCTAssertEqual(seconds.rawNanoseconds, 1_500_000_000)
        XCTAssertEqual(seconds.nativeValue, .double(1.5))
        XCTAssertEqual(seconds.nativeUnit, .seconds)
    }

    func testFieldSampleInvariants() {
        XCTAssertThrowsError(try FieldSample(status: .valid, rawNanoseconds: nil, nativeValue: nil,
                                             api: "x", nativeUnit: .nanoseconds, nativeClockDomain: nil))
        XCTAssertThrowsError(try FieldSample(status: .pending, rawNanoseconds: 1, nativeValue: nil,
                                             api: "x", nativeUnit: nil, nativeClockDomain: nil))
        // Rounding is half away from zero, per contract.
        let negative = FieldSample.validSeconds(-0.0000000005, api: "test")
        XCTAssertEqual(negative.rawNanoseconds, -1)
    }
}
