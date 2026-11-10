import AppKit
import Metal
import OpticCore
import QuartzCore

/// Identity frozen at segment start. A late presented callback always uses this
/// value, never "the current segment".
public struct FrozenSegment {
    public let sessionID: SessionID
    public let config: SegmentConfig
    public let layout: LayoutSpec
    public let surfaceInstanceID: String

    public init(sessionID: SessionID, config: SegmentConfig, layout: LayoutSpec, surfaceInstanceID: String) {
        self.sessionID = sessionID
        self.config = config
        self.layout = layout
        self.surfaceInstanceID = surfaceInstanceID
    }
}

/// What the display link should do on its next callback.
public enum FramePlan {
    case idle
    /// Keep the last presented drawable; do not submit (no new render_seq, no event).
    case held
    case dynamic(FrozenSegment)
    case card(FrozenSegment, kind: DisplayFrameKind, phase: SessionPhase, text: CardText?, token: Int)
    case calibration(FrozenSegment, screen: CalibrationScreen, token: Int)
    case preview(layout: LayoutSpec, text: CardText?, token: Int)
}

/// Merges the two asynchronous callbacks of one submission (drawable presented,
/// command buffer completed) into one result row. Whichever callback arrives
/// last delivers; no thread blocks.
private final class FrameOutcome {
    enum Presented {
        case valid(sample: FieldSample, platformIDs: PlatformIDs, recordedRawNanoseconds: Int64)
        case invalid(sample: FieldSample, platformIDs: PlatformIDs, recordedRawNanoseconds: Int64)
    }

    private let lock = NSLock()
    private let identity: FrameIdentity
    private let evidence: Evidence
    private let recorder: PresentationRecorder
    private var presented: Presented?
    private var renderComplete: FieldSample?
    private var completionArrived = false
    private var delivered = false

    init(identity: FrameIdentity, evidence: Evidence, recorder: PresentationRecorder) {
        self.identity = identity
        self.evidence = evidence
        self.recorder = recorder
    }

    func recordPresented(_ outcome: Presented) {
        lock.lock()
        presented = outcome
        let ready = completionArrived && !delivered
        if ready { delivered = true }
        lock.unlock()
        if ready { deliver() }
    }

    func recordCompletion(gpuEnd: FieldSample?) {
        lock.lock()
        renderComplete = gpuEnd
        completionArrived = true
        let ready = presented != nil && !delivered
        if ready { delivered = true }
        lock.unlock()
        if ready { deliver() }
    }

    private func deliver() {
        lock.lock()
        let outcome = presented
        let complete = renderComplete
        lock.unlock()
        guard let outcome else { return }
        switch outcome {
        case let .valid(sample, ids, recorded):
            recorder.presented(identity, evidence: evidence, systemPresent: sample,
                               renderComplete: complete, platformIDs: ids, at: recorded)
        case let .invalid(sample, ids, recorded):
            recorder.unconfirmed(identity, reason: .timestampInvalid, systemPresent: sample,
                                 renderComplete: complete, platformIDs: ids, at: recorded)
        }
    }
}

/// The only time source that advances frames. Phase transitions are driven by
/// the controller, but every submission is created inside this delegate callback.
@MainActor
public final class FrameDriver: NSObject, CAMetalDisplayLinkDelegate {
    public private(set) var plan: FramePlan = .idle
    public var onOverflow: (() -> Void)?
    /// Called when the drawable size no longer matches the frozen layout. The
    /// controller must close the segment at a safe switch point; the driver
    /// stops submitting until the plan changes.
    public var onSurfaceMismatch: ((PixelSize) -> Void)?
    public var allocateRenderSeq: (() -> RenderSeq?)?
    public var onFrameSubmitted: ((FrameIdentity) -> Void)?

    private let view: MetalHostView
    private let renderer: MetalRenderer
    private let recorder: PresentationRecorder?
    private let clock: MonotonicClock
    private let surfaceInstanceID: String
    private let allocator = FrameIdentityAllocator()
    private var displayLink: CAMetalDisplayLink?
    private var lastPreviewToken: Int = .min
    private var previewLayout: LayoutSpec?
    private var preferredRefresh: RefreshRate?

    public init(
        view: MetalHostView,
        device: MTLDevice,
        recorder: PresentationRecorder?,
        clock: MonotonicClock,
        surfaceInstanceID: String
    ) throws {
        self.view = view
        self.renderer = try MetalRenderer(device: device)
        self.recorder = recorder
        self.clock = clock
        self.surfaceInstanceID = surfaceInstanceID
        super.init()
    }

    public func setPlan(_ plan: FramePlan) {
        self.plan = plan
    }

    public func setPreferredRefresh(_ rate: RefreshRate?) {
        preferredRefresh = rate
        applyFrameRateRange()
    }

    public func start() {
        guard displayLink == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: view.metalLayer)
        link.delegate = self
        applyFrameRateRange(to: link)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public func pause() {
        displayLink?.isPaused = true
    }

    public func resume() {
        displayLink?.isPaused = false
    }

    public func stop() {
        guard let displayLink else { return }
        displayLink.isPaused = true
        displayLink.remove(from: .main, forMode: .common)
        displayLink.invalidate()
        self.displayLink = nil
    }

    public var isRunning: Bool { displayLink != nil }

    public var drawableSize: PixelSize { view.currentDrawableSize }

    private func applyFrameRateRange(to link: CAMetalDisplayLink? = nil) {
        guard let target = link ?? displayLink else { return }
        // Only override when the operator requested a rate; M-CAL keeps the
        // system default range.
        if let rate = preferredRefresh {
            let hz = Float(rate.hertz)
            target.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
        }
    }

    // MARK: - Delegate

    public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        switch plan {
        case .idle, .held:
            return
        case .dynamic(let segment):
            guard surfaceMatches(segment.layout, update.drawable) else { return }
            submitDynamic(segment, update)
        case let .card(segment, kind, phase, text, _):
            guard surfaceMatches(segment.layout, update.drawable) else { return }
            // One submission per display-link update, as the design describes.
            // Isolated presentations on an idle layer are reported as skipped
            // (presentedTime 0) on this machine, so static content is presented
            // continuously while its phase lasts.
            var scene = SceneBuilder.cardScene(segment.layout)
            if text != nil {
                scene.text = SceneBuilder.textQuad(
                    patternRect: SceneBuilder.patternTextRect(segment.layout),
                    patternSize: segment.layout.patternSize,
                    rotationDeg: segment.layout.patternRotationDeg
                )
            }
            submitStatic(scene: scene, text: text, segment: segment,
                         kind: kind, phase: phase, update: update)
        case let .calibration(segment, screen, _):
            guard surfaceMatches(segment.layout, update.drawable) else { return }
            // Same per-update submission rule as cards: calibration patterns
            // need real presentation evidence for every held frame.
            let scene = SceneBuilder.calibrationScene(segment.layout, screen)
            submitStatic(scene: scene, text: nil, segment: segment,
                         kind: .calibration, phase: .calibration, update: update)
        case let .preview(layout, text, token):
            let drawable = update.drawable
            let actual = PixelSize(width: drawable.texture.width, height: drawable.texture.height)
            let sizeChanged = previewLayout?.drawableSize != actual
            guard token != lastPreviewToken || sizeChanged else { return }
            lastPreviewToken = token
            // A resize rebuilds the sample layout once and redraws; the preview
            // remains a one-shot render, not a full-rate loop.
            let usable = (try? LayoutBuilder.make(
                layoutID: layout.layoutID,
                geometryProfile: layout.geometryProfile,
                drawable: actual,
                rotationDeg: layout.patternRotationDeg,
                levels: layout.levels
            )) ?? layout
            previewLayout = usable
            let bits = PatternEncoder.encode(RenderSeq(0), profile: usable.profile)
            let scene = SceneBuilder.dynamicScene(usable, bits: bits)
            guard let buffer = renderer.makeCommandBuffer(drawable: drawable, scene: scene, text: text) else { return }
            buffer.present(drawable)
            buffer.commit()
        }
    }

    /// The frozen layout is never drawn into a different drawable size.
    private func surfaceMatches(_ layout: LayoutSpec, _ drawable: CAMetalDrawable) -> Bool {
        let actual = PixelSize(width: drawable.texture.width, height: drawable.texture.height)
        guard actual == layout.drawableSize else {
            plan = .held
            onSurfaceMismatch?(actual)
            return false
        }
        return true
    }

    // MARK: - Submission

    private func submitDynamic(_ segment: FrozenSegment, _ update: CAMetalDisplayLink.Update) {
        guard let recorder, let seq = allocateRenderSeq?() else { return }
        let bits = PatternEncoder.encode(seq, profile: segment.layout.profile)
        guard let identity = try? FrameIdentity(
            sessionID: segment.sessionID,
            segmentID: segment.config.segmentID,
            layoutID: segment.layout.layoutID,
            nativeFrameID: allocator.allocate(),
            frameKind: .dynamic,
            phase: .running,
            renderSeq: seq,
            pattern: bits
        ) else { return }

        switch recorder.begin(identity) {
        case .blockedByOverflow:
            plan = .held
            onOverflow?()
            return
        case .sealed, .duplicateFrameID:
            return
        case .tracking, .pendingQueueFull:
            break
        }

        let scene = SceneBuilder.dynamicScene(segment.layout, bits: bits)
        submit(scene: scene, text: nil, identity: identity, segment: segment, update: update)
    }

    private func submitStatic(
        scene: Scene,
        text: CardText?,
        segment: FrozenSegment,
        kind: DisplayFrameKind,
        phase: SessionPhase,
        update: CAMetalDisplayLink.Update
    ) {
        guard let recorder else { return }
        guard let identity = try? FrameIdentity(
            sessionID: segment.sessionID,
            segmentID: segment.config.segmentID,
            layoutID: segment.layout.layoutID,
            nativeFrameID: allocator.allocate(),
            frameKind: kind,
            phase: phase
        ) else { return }
        switch recorder.begin(identity) {
        case .blockedByOverflow:
            plan = .held
            onOverflow?()
            return
        case .sealed, .duplicateFrameID:
            return
        case .tracking, .pendingQueueFull:
            submit(scene: scene, text: text, identity: identity, segment: segment, update: update)
        }
    }

    private func submit(
        scene: Scene,
        text: CardText?,
        identity: FrameIdentity,
        segment: FrozenSegment,
        update: CAMetalDisplayLink.Update
    ) {
        guard let recorder else { return }
        let drawable = update.drawable
        guard let buffer = renderer.makeCommandBuffer(drawable: drawable, scene: scene, text: text) else {
            recorder.abandon(identity, operation: "makeCommandBuffer", errorCode: nil,
                             message: "Metal command buffer or render encoder unavailable")
            return
        }

        let targetPresent = FieldSample.validSeconds(
            update.targetPresentationTimestamp,
            api: "CAMetalDisplayLink.Update.targetPresentationTimestamp"
        )
        let deadline = FieldSample.validSeconds(
            update.targetTimestamp,
            api: "CAMetalDisplayLink.Update.targetTimestamp"
        )
        let submitRaw = clock.rawNanoseconds()
        let submitSample = FieldSample.valid(
            rawNanoseconds: submitRaw,
            nativeValue: .int(submitRaw),
            api: "CLOCK_UPTIME_RAW"
        )
        let evidence = Evidence.submission(
            targetPresent: targetPresent,
            deadline: deadline,
            submit: submitSample,
            systemPresent: .pending(api: "MTLDrawable.presentedTime"),
            renderComplete: .pending(api: "MTLCommandBuffer.GPUEndTime"),
            latch: .unsupported(api: "no-public-latch-query")
        )
        let platformIDs = PlatformIDs(
            surfaceInstanceID: segment.surfaceInstanceID,
            drawableID: String(drawable.drawableID)
        )

        // The closures capture the identity; drawable_id is diagnostic only and
        // is never used to look anything up. Both callbacks must arrive before
        // the result row is written, so the row carries the real GPU end time.
        let clock = self.clock
        let surface = segment.surfaceInstanceID
        let outcome = FrameOutcome(identity: identity, evidence: evidence, recorder: recorder)
        drawable.addPresentedHandler { presented in
            let ids = PlatformIDs(
                surfaceInstanceID: surface,
                drawableID: String(presented.drawableID)
            )
            let recorded = clock.rawNanoseconds()
            if presented.presentedTime > 0 {
                outcome.recordPresented(.valid(
                    sample: .validSeconds(presented.presentedTime, api: "MTLDrawable.presentedTime"),
                    platformIDs: ids,
                    recordedRawNanoseconds: recorded
                ))
            } else {
                outcome.recordPresented(.invalid(
                    sample: .invalid(nativeValue: .double(0),
                                     api: "MTLDrawable.presentedTime",
                                     nativeUnit: .seconds),
                    platformIDs: ids,
                    recordedRawNanoseconds: recorded
                ))
            }
        }
        buffer.addCompletedHandler { completed in
            if completed.status == .error {
                let nsError = completed.error as NSError?
                let code = nsError.map { "\($0.domain):\($0.code)" }
                recorder.recordRenderFailureAfterSubmit(
                    identity,
                    operation: "MTLCommandBuffer.status",
                    errorCode: code,
                    message: completed.error?.localizedDescription ?? "command buffer failed"
                )
            }
            // E1 verified gpuEndTime is host seconds in the session clock
            // domain. A zero value is not turned into a fabricated timestamp.
            let gpuEnd = completed.gpuEndTime
            let sample: FieldSample? = gpuEnd > 0
                ? .validSeconds(gpuEnd, api: "MTLCommandBuffer.gpuEndTime")
                : nil
            outcome.recordCompletion(gpuEnd: sample)
        }

        buffer.present(drawable)
        buffer.commit()
        recorder.submitted(identity, evidence: evidence, platformIDs: platformIDs, at: submitRaw)
        onFrameSubmitted?(identity)
    }
}
