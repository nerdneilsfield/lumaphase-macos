import Foundation

/// Measured distribution for one interval. Only real samples are included; an
/// empty distribution is not written at all rather than being filled with
/// zeros.
public struct TimingDistribution: Equatable {
    public let count: Int
    public let minNS: Int64
    public let p50NS: Int64
    public let p90NS: Int64
    public let maxNS: Int64

    public init(samples: [Int64]) {
        let sorted = samples.sorted()
        count = sorted.count
        minNS = sorted.first ?? 0
        maxNS = sorted.last ?? 0
        p50NS = TimingDistribution.percentile(sorted, 0.50)
        p90NS = TimingDistribution.percentile(sorted, 0.90)
    }

    private static func percentile(_ sorted: [Int64], _ fraction: Double) -> Int64 {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    public func json() -> JSONValue {
        .object([
            "count": .int(Int64(count)),
            "min": .int(minNS),
            "p50": .int(p50NS),
            "p90": .int(p90NS),
            "max": .int(maxNS)
        ])
    }
}

/// Session-level timing summary (design §10). All values are measured from
/// logged evidence: submit is the CPU sample before the submit path, GPU end is
/// `MTLCommandBuffer.gpuEndTime`, and presentation is `MTLDrawable.presentedTime`.
/// No CPU callback arrival time is substituted for a GPU timestamp.
public struct TimingStatistics: Equatable {
    public var submitToPresent: TimingDistribution?
    public var submitToRenderComplete: TimingDistribution?
    public var renderCompleteToPresent: TimingDistribution?
    /// Per-segment adjacent positive differences of real presentation times
    /// (unique frames only). Segment boundaries and repeated callbacks cannot
    /// create a hold interval.
    public var presentedInterval: TimingDistribution?

    public init(
        submitToPresent: TimingDistribution? = nil,
        submitToRenderComplete: TimingDistribution? = nil,
        renderCompleteToPresent: TimingDistribution? = nil,
        presentedInterval: TimingDistribution? = nil
    ) {
        self.submitToPresent = submitToPresent
        self.submitToRenderComplete = submitToRenderComplete
        self.renderCompleteToPresent = renderCompleteToPresent
        self.presentedInterval = presentedInterval
    }

    public static let empty = TimingStatistics()

    public var isEmpty: Bool {
        submitToPresent == nil && submitToRenderComplete == nil
            && renderCompleteToPresent == nil && presentedInterval == nil
    }

    public func json() -> JSONValue {
        var members: JSONObject = [:]
        if let submitToPresent { members["submit_to_present_ns"] = submitToPresent.json() }
        if let submitToRenderComplete { members["submit_to_render_complete_ns"] = submitToRenderComplete.json() }
        if let renderCompleteToPresent { members["render_complete_to_present_ns"] = renderCompleteToPresent.json() }
        if let presentedInterval { members["presented_interval_ns"] = presentedInterval.json() }
        return .object(members)
    }
}
