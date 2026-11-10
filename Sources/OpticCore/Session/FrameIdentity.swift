import Foundation

/// Immutable frame identity captured at submission time. It is never rebuilt
/// from "the current segment" when a late callback arrives.
public struct FrameIdentity: Hashable {
    public let sessionID: SessionID
    public let segmentID: SegmentID
    public let layoutID: String
    public let nativeFrameID: NativeFrameID
    public let frameKind: DisplayFrameKind
    public let phase: SessionPhase
    public let renderSeq: RenderSeq?
    public let pattern: PatternBits?

    public init(
        sessionID: SessionID,
        segmentID: SegmentID,
        layoutID: String,
        nativeFrameID: NativeFrameID,
        frameKind: DisplayFrameKind,
        phase: SessionPhase,
        renderSeq: RenderSeq? = nil,
        pattern: PatternBits? = nil
    ) throws {
        guard phase.isDisplayPhase else { throw FrameIdentityError.nonDisplayPhase(phase) }
        switch frameKind {
        case .dynamic:
            guard let renderSeq, let pattern else {
                throw FrameIdentityError.dynamicFrameMissingEncoding
            }
            guard pattern.renderSeq == renderSeq else {
                throw FrameIdentityError.renderSeqMismatch(identity: renderSeq.description,
                                                           pattern: pattern.renderSeq.description)
            }
            guard pattern.bits.count == pattern.profile.moduleCount,
                  pattern.bits.allSatisfy({ $0 == 0 || $0 == 1 })
            else {
                throw FrameIdentityError.dynamicFrameMissingEncoding
            }
        default:
            guard renderSeq == nil, pattern == nil else {
                throw FrameIdentityError.staticFrameCarriesEncoding
            }
        }
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.layoutID = layoutID
        self.nativeFrameID = nativeFrameID
        self.frameKind = frameKind
        self.phase = phase
        self.renderSeq = renderSeq
        self.pattern = pattern
    }
}

public enum FrameIdentityError: Error, Equatable {
    case nonDisplayPhase(SessionPhase)
    case dynamicFrameMissingEncoding
    case staticFrameCarriesEncoding
    case renderSeqMismatch(identity: String, pattern: String)
}
