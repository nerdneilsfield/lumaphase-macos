import Foundation

/// Monotonic clock in the session's standard domain. The display layer supplies
/// `SystemUptimeClock`; tests supply a fake.
public protocol MonotonicClock {
    /// Raw nanoseconds in the session clock domain; not Unix time.
    func rawNanoseconds() -> Int64
}

/// `CLOCK_UPTIME_RAW` is the mach host-time domain used by Metal's
/// `presentedTime` and the display link timestamps. T2 must still verify that
/// claim empirically on the target machine; this type only names the source.
public struct SystemUptimeClock: MonotonicClock {
    public init() {}

    public func rawNanoseconds() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }
}

/// Origin subtraction required by contract §6.1. It never re-zeroes inside one
/// session.
public struct SessionTimeBase: Equatable {
    public let originRawNanoseconds: Int64

    public init(originRawNanoseconds: Int64) {
        self.originRawNanoseconds = originRawNanoseconds
    }

    public init(clock: MonotonicClock) {
        self.originRawNanoseconds = clock.rawNanoseconds()
    }

    public func relative(_ rawNanoseconds: Int64) -> Int64 {
        rawNanoseconds - originRawNanoseconds
    }

    public func json() -> JSONValue {
        .object([
            "raw_ns": .int(originRawNanoseconds),
            "native_clock": .string(SessionClockDomain.macOSHostTime)
        ])
    }
}

public enum SessionClockDomain {
    public static let macOSHostTime = "MACOS_HOST_TIME"
    /// Fixed by contract: drain after the end card, before sealing.
    public static let presentationDrainTimeoutNanoseconds: Int64 = 2_000_000_000
}

/// Per-field evidence for one event. A field is valid only when both the native
/// raw value and the relative nanoseconds exist.
public struct FieldSample: Equatable {
    public let status: TimestampStatus
    public let rawNanoseconds: Int64?
    /// Native API value: decimal string for integers, number for seconds, null
    /// when there is nothing to keep.
    public let nativeValue: JSONValue?
    public let api: String
    public let nativeUnit: NativeTimeUnit?
    public let nativeClockDomain: String?
    public let queryErrorCode: String?

    public init(
        status: TimestampStatus,
        rawNanoseconds: Int64?,
        nativeValue: JSONValue?,
        api: String,
        nativeUnit: NativeTimeUnit?,
        nativeClockDomain: String?,
        queryErrorCode: String? = nil
    ) throws {
        if status == .valid {
            guard rawNanoseconds != nil else { throw FieldSampleError.missingRawNanoseconds(status) }
            self.rawNanoseconds = rawNanoseconds
        } else {
            // Contract: non-VALID statuses carry no standard nanoseconds. A
            // native value may still be preserved for diagnostics.
            guard rawNanoseconds == nil else { throw FieldSampleError.rawNanosecondsOnNonValid(status) }
            self.rawNanoseconds = nil
        }
        var normalizedNative = nativeValue
        if let nativeValue {
            switch nativeValue {
            case .int(let value) where nativeUnit == .nanoseconds:
                // Contract §6.2: integer native values travel as decimal
                // strings so a 64-bit value cannot be lost in JSON.
                normalizedNative = .string(String(value))
            case .null, .string, .int, .double:
                break
            default:
                throw FieldSampleError.invalidNativeValue
            }
        }
        self.status = status
        self.nativeValue = normalizedNative
        self.api = api
        self.nativeUnit = nativeUnit
        self.nativeClockDomain = nativeClockDomain
        self.queryErrorCode = queryErrorCode
    }

    public static func valid(
        rawNanoseconds: Int64,
        nativeValue: JSONValue?,
        api: String,
        nativeUnit: NativeTimeUnit = .nanoseconds,
        nativeClockDomain: String = SessionClockDomain.macOSHostTime
    ) -> FieldSample {
        // The factory cannot fail: raw is non-optional and nativeValue was
        // already constrained by callers to JSON scalars.
        try! FieldSample(
            status: .valid,
            rawNanoseconds: rawNanoseconds,
            nativeValue: nativeValue,
            api: api,
            nativeUnit: nativeUnit,
            nativeClockDomain: nativeClockDomain
        )
    }

    /// Metal returns `CFTimeInterval` seconds. The contract conversion rounds
    /// half away from zero; it does not claim nanosecond API precision.
    public static func validSeconds(
        _ seconds: Double,
        api: String,
        nativeClockDomain: String = SessionClockDomain.macOSHostTime
    ) -> FieldSample {
        let nanoseconds = Int64((seconds * 1_000_000_000).rounded(.toNearestOrAwayFromZero))
        return valid(
            rawNanoseconds: nanoseconds,
            nativeValue: .double(seconds),
            api: api,
            nativeUnit: .seconds,
            nativeClockDomain: nativeClockDomain
        )
    }

    public static func pending(api: String) -> FieldSample {
        try! FieldSample(status: .pending, rawNanoseconds: nil, nativeValue: nil, api: api,
                         nativeUnit: nil, nativeClockDomain: nil)
    }

    public static func invalid(nativeValue: JSONValue?, api: String, nativeUnit: NativeTimeUnit? = nil) -> FieldSample {
        try! FieldSample(status: .invalid, rawNanoseconds: nil, nativeValue: nativeValue, api: api,
                         nativeUnit: nativeUnit, nativeClockDomain: nil)
    }

    public static func unsupported(api: String) -> FieldSample {
        try! FieldSample(status: .unsupported, rawNanoseconds: nil, nativeValue: nil, api: api,
                         nativeUnit: nil, nativeClockDomain: nil)
    }

    public static func notApplicable() -> FieldSample {
        try! FieldSample(status: .notApplicable, rawNanoseconds: nil, nativeValue: nil, api: "",
                         nativeUnit: nil, nativeClockDomain: nil)
    }

    public static func queryFailed(api: String, errorCode: String?) -> FieldSample {
        try! FieldSample(status: .queryFailed, rawNanoseconds: nil, nativeValue: nil, api: api,
                         nativeUnit: nil, nativeClockDomain: nil, queryErrorCode: errorCode)
    }

    /// A native value exists but its clock domain is not proven to be the
    /// session domain. The native value stays; standard fields stay null.
    public static func clockDomainUnverified(
        nativeValue: JSONValue,
        api: String,
        nativeUnit: NativeTimeUnit,
        nativeClockDomain: String? = nil
    ) -> FieldSample {
        try! FieldSample(status: .clockDomainUnverified, rawNanoseconds: nil, nativeValue: nativeValue,
                         api: api, nativeUnit: nativeUnit, nativeClockDomain: nativeClockDomain)
    }

    /// Relative nanoseconds for a valid sample, else nil.
    public func relativeNanoseconds(_ timeBase: SessionTimeBase) -> Int64? {
        rawNanoseconds.map(timeBase.relative)
    }

    func jsonEntry() -> JSONValue {
        .object([
            "api": .string(api),
            "native_value": nativeValue ?? .null,
            "native_unit": nativeUnit.map { .string($0.rawValue) } ?? .null,
            "native_clock_domain": nativeClockDomain.map(JSONValue.string) ?? .null,
            "query_error_code": queryErrorCode.map(JSONValue.string) ?? .null
        ])
    }
}

public enum FieldSampleError: Error, Equatable {
    case missingRawNanoseconds(TimestampStatus)
    case rawNanosecondsOnNonValid(TimestampStatus)
    case invalidNativeValue
}

/// The six standard timestamp fields plus their statuses. Keys are the contract
/// prefixes. `recorded` is kept separately on each event because it is always
/// valid.
public struct Evidence: Equatable {
    private var samples: [TimestampField: FieldSample]

    public init() {
        var samples: [TimestampField: FieldSample] = [:]
        for field in TimestampField.allCases {
            samples[field] = .notApplicable()
        }
        self.samples = samples
    }

    public init(_ samples: [TimestampField: FieldSample]) {
        var merged: [TimestampField: FieldSample] = [:]
        for field in TimestampField.allCases {
            merged[field] = samples[field] ?? .notApplicable()
        }
        self.samples = merged
    }

    public subscript(field: TimestampField) -> FieldSample {
        get { samples[field] ?? .notApplicable() }
        set { samples[field] = newValue }
    }

    /// Convenience for a macOS submission: the system present time is pending
    /// until the presented callback, latch is unsupported (no public query on
    /// macOS). T2 must pass `renderComplete` explicitly: this core does not
    /// sample GPU completion, so leaving the default would claim more than the
    /// T1 path provides.
    public static func submission(
        targetPresent: FieldSample,
        deadline: FieldSample,
        submit: FieldSample,
        systemPresent: FieldSample = .pending(api: "MTLDrawable.presentedTime"),
        renderComplete: FieldSample = .unsupported(api: "MTLCommandBuffer.GPUEndTime"),
        latch: FieldSample = .unsupported(api: "no-public-latch-query")
    ) -> Evidence {
        Evidence([
            .targetPresent: targetPresent,
            .deadline: deadline,
            .submit: submit,
            .systemPresent: systemPresent,
            .renderComplete: renderComplete,
            .latch: latch
        ])
    }

    public func jsonRaw(_ timeBase: SessionTimeBase) -> JSONObject {
        var members: JSONObject = [:]
        for field in TimestampField.allCases {
            let sample = self[field]
            let raw = sample.rawNanoseconds.map { JSONValue.int($0) } ?? .null
            let relative = sample.relativeNanoseconds(timeBase).map { JSONValue.int($0) } ?? .null
            members["\(field.rawValue)_raw_ns"] = raw
            members["\(field.rawValue)_ns"] = relative
        }
        return members
    }

    public func jsonStatus() -> JSONValue {
        var members: JSONObject = [:]
        for field in TimestampField.allCases {
            members[field.rawValue] = .string(self[field].status.rawValue)
        }
        return .object(members)
    }

    public func jsonPlatformTimestamps() -> JSONValue {
        var members: JSONObject = [:]
        for field in TimestampField.allCases {
            members[field.rawValue] = self[field].jsonEntry()
        }
        return .object(members)
    }
}
