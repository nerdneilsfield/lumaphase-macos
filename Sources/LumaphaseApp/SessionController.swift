import AppKit
import Combine
import Metal
import OpticCore
import OpticDisplay

/// Session orchestration: settings, phase timeline, segment boundaries and the
/// single display link that renders frames.
@MainActor
final class SessionController: NSObject, ObservableObject {
    // MARK: - Operator settings
    @Published var profile: ExperimentProfile = .m59S1
    @Published private(set) var geometryProfile: GeometryProfile = .f68G6x12
    @Published var rotationDeg: Int = 0
    @Published var lowLevel: Int = 32
    @Published var highLevel: Int = 224
    @Published var runningSeconds: Double = 90
    @Published var windowed: Bool = false
    @Published var brightnessText: String = ""
    @Published var operatorNote: String = ""
    @Published var outputDirectory: URL = SessionController.defaultOutputDirectory()
    @Published var calibrationGeometry = true
    @Published var calibrationStaircase = true
    @Published var calibrationFlip = true

    // MARK: - Runtime status
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var statusText = "就绪。选择配置后开始，或先预览。"
    @Published private(set) var sessionText = "—"
    @Published private(set) var submittedCount = 0
    @Published private(set) var presentedCount = 0
    @Published private(set) var unconfirmedCount = 0
    @Published private(set) var exportPath: String?
    @Published private(set) var exportFailed = false
    @Published private(set) var displayInfoText = "启动时读取显示器信息"
    @Published private(set) var isBusy = false
    @Published private(set) var importedProfileID: String?
    @Published private(set) var importedProfileStatus = "未导入标定"
    @Published private(set) var canPause = false
    @Published private(set) var smokeProgress = ""

    private enum RunState {
        case idle
        case preparing
        case warmup
        case sessionCard
        case running
        case endCard
        case draining
        case paused
        case calibrating
        case finished
    }

    private enum CloseReason {
        case normal
        case userStop
        case overflow
        case renderFailure
    }

    /// Settings are frozen when the session starts. UI edits during a session
    /// cannot leak into later segments or the export.
    private struct FrozenConfig {
        var profile: ExperimentProfile
        var geometryProfile: GeometryProfile
        var rotationDeg: Int
        var lowLevel: Int
        var highLevel: Int
        var runningNanoseconds: Int64
        var outputDirectory: URL
        var brightness: Double?
        var operatorNote: String
        var importedProfile: ImportedCalibrationProfile?
        var windowed: Bool
        var calibrationGeometry: Bool
        var calibrationStaircase: Bool
        var calibrationFlipEnabled: Bool

        var levels: PatternLevels {
            PatternLevels(low: UInt8(clamping: lowLevel), high: UInt8(clamping: highLevel))
        }
    }

    private let options: AppOptions
    private let clock = SystemUptimeClock()
    private var timeBase: SessionTimeBase?
    private var sessionID: SessionID?
    private var package: SessionPackage?
    private var recorder: PresentationRecorder?
    private var driver: FrameDriver?
    private var displayWindow: DisplayWindowController?
    private var previewWindow: DisplayWindowController?
    private var previewDriver: FrameDriver?
    private var timer: DispatchSourceTimer?

    private var state: RunState = .idle
    private var currentSegment: FrozenSegment?
    private var nextSegmentIndex: UInt32 = 0
    private var nextLayoutIndex = 0
    private var nextSeqValue: UInt64 = 0
    private var staticToken = 0
    private var phaseDeadline: Int64 = 0
    private var runningDeadline: Int64 = 0
    private var pausedRemaining: Int64 = 0
    private var runStartRaw: Int64 = 0
    private var closeReason: CloseReason = .normal
    private var currentScreen: NSScreen?
    private var displaySignature = ""
    private var device: MTLDevice?
    private var preparingSize: PixelSize?
    private var preparingSettledAt: Int64 = 0
    private var lastDisplayCheck: Int64 = 0
    private var lastStatusUpdate: Int64 = 0
    private var smokeResizeAt: Int64 = 0
    private var smokePauseAt: Int64 = 0
    private var smokeResumeAt: Int64 = 0
    private var smokeResizeDone = false
    private var smokePauseDone = false
    private var importedProfile: ImportedCalibrationProfile?
    private var config: FrozenConfig?
    private var quitCompletion: ((Bool) -> Void)?
    private var pendingEndReason: SegmentEndReason = .configurationChanged
    private var restartPending = false
    private var pausedBySystem = false
    private var fullscreenObserver: NSObjectProtocol?
    private var calibrationSteps: [(duration: Int64, screen: CalibrationScreen, note: String)] = []
    private var calibrationIndex = 0
    private var calibrationStepDeadline: Int64 = 0
    private var calibrationFlipAt: Int64 = 0
    private var calibrationFlipState = false

    private var isSmoke: Bool { options.smoke }
    private var effectiveWindowed: Bool {
        if let config { return config.windowed || options.smoke }
        return options.windowed || options.smoke || windowed
    }

    init(options: AppOptions) {
        self.options = options
        super.init()
        apply(options: options)
        refreshDisplayInfo()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    // MARK: - Settings application

    private func apply(options: AppOptions) {
        profile = options.profile
        geometryProfile = options.geometryProfile
        rotationDeg = options.rotationDeg
        if let seconds = options.runningSeconds { runningSeconds = seconds }
        if let output = options.outputDirectory { outputDirectory = output }
        windowed = options.windowed || options.smoke
    }

    var canChangeGeometry: Bool { !isBusy || state == .running || state == .paused }

    func changeGeometry(_ geometry: GeometryProfile) {
        guard canChangeGeometry, geometry != geometryProfile else { return }
        geometryProfile = geometry
        if config != nil, state == .running || state == .paused {
            config?.geometryProfile = geometry
            if state == .running {
                rebuildSegment(endReason: .configurationChanged)
            }
            // A paused session has no active segment; resume creates the new one.
        }
    }

    private func makeLevels() -> PatternLevels {
        if let config { return config.levels }
        return PatternLevels(low: UInt8(clamping: lowLevel), high: UInt8(clamping: highLevel))
    }

    private var brightnessValue: Double? {
        let trimmed = brightnessText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), value >= 0, value <= 1 else { return nil }
        return value
    }

    // MARK: - Display information

    func refreshDisplayInfo() {
        guard let screen = DisplayInfo.preferredScreen() else {
            displayInfoText = "没有可用显示器"
            return
        }
        let info = DisplayInspector.info(for: screen)
        currentScreen = screen
        let requested = profile.requestedRefresh.map { String(format: "%.2f Hz（请求）", $0.hertz) } ?? "未请求"
        let actual = info.refreshHz.map { String(format: "%.2f Hz（系统模式）", $0) } ?? "系统模式未报告"
        displayInfoText = """
        模式 ID：\(info.modeID ?? "null")
        模式像素：\(info.modePixelSize.width)×\(info.modePixelSize.height)
        刷新：\(requested) / \(actual) / 上限 \(info.maximumFramesPerSecond) Hz
        色彩空间：\(info.colorSpaceName)
        旋转原始值：\(String(format: "%.1f", info.rotationRawDegrees))°（标准字段留空）
        """
    }

    // MARK: - Preview

    func preview() {
        guard state == .idle || state == .finished else { return }
        closePreview()
        guard let screen = DisplayInfo.preferredScreen(),
              let device = MTLCreateSystemDefaultDevice()
        else {
            statusText = "预览失败：没有 Metal 设备或显示器"
            return
        }
        let info = DisplayInspector.info(for: screen)
        let window = DisplayWindowController(screen: screen, windowed: true, verification: false,
                                             device: device)
        previewWindow = window
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.drawPreview(device: device, window: window)
        }
    }

    private func drawPreview(device: MTLDevice, window: DisplayWindowController) {
        guard (previewWindow === window) else { return }
        let size = window.hostView.currentDrawableSize
        guard size.width > 100, size.height > 100 else {
            statusText = "预览窗口尺寸不可用"
            return
        }
        do {
            let layout = try LayoutBuilder.make(
                layoutID: "preview",
                geometryProfile: geometryProfile,
                drawable: size,
                rotationDeg: rotationDeg,
                levels: makeLevels()
            )
            let driver = try FrameDriver(view: window.hostView, device: device, recorder: nil,
                                         clock: clock, surfaceInstanceID: window.surfaceInstanceID)
            driver.setPlan(.preview(layout: layout, text: nil, token: 1))
            driver.start()
            previewDriver = driver
            statusText = "预览中：\(geometryProfile.rawValue) 示例状态，未创建会话、未写日志。"
        } catch {
            statusText = "预览失败：\(error)"
        }
    }

    func closePreview() {
        previewDriver?.stop()
        previewDriver = nil
        previewWindow?.close()
        previewWindow = nil
    }

    // MARK: - Calibration import

    func importCalibration() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择标定 JSON（profile_id、calibration_key、model）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let json = try JSONParser.parse(data)
            guard let profileID = json["profile_id"]?.stringValue,
                  let keyJSON = json["calibration_key"],
                  let model = json["model"]
            else {
                throw CalibrationError.invalidKey
            }
            let key = try CalibrationKey(json: keyJSON)
            importedProfile = ImportedCalibrationProfile(profileID: profileID, key: key, model: model)
            importedProfileID = profileID
            importedProfileStatus = "已导入 \(profileID)（标定版本 \(key.calibrationVersion)），模型不透明保留"
            statusText = "标定已导入，将在下一个会话段引用；模型不参与显示计算。"
        } catch {
            importedProfileStatus = "导入失败：\(error)"
        }
    }

    func clearCalibration() {
        guard !isBusy else { return }
        importedProfile = nil
        importedProfileID = nil
        importedProfileStatus = "未导入标定"
    }

    // MARK: - Output directory

    func chooseOutputDirectory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.message = "选择会话导出目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
    }

    // MARK: - Session control

    func start() {
        guard state == .idle || state == .finished else { return }
        guard !isBusy else { return }
        config = FrozenConfig(
            profile: profile,
            geometryProfile: geometryProfile,
            rotationDeg: rotationDeg,
            lowLevel: lowLevel,
            highLevel: highLevel,
            runningNanoseconds: Int64(max(1, runningSeconds) * 1_000_000_000),
            outputDirectory: outputDirectory,
            brightness: brightnessValue,
            operatorNote: operatorNote,
            importedProfile: importedProfile,
            windowed: windowed,
            calibrationGeometry: calibrationGeometry,
            calibrationStaircase: calibrationStaircase,
            calibrationFlipEnabled: calibrationFlip
        )
        isBusy = true
        exportPath = nil
        exportFailed = false
        closePreview()
        do {
            try prepareSession()
        } catch {
            isBusy = false
            statusText = "启动失败：\(error)"
            state = .idle
        }
    }

    private func prepareSession() throws {
        guard let screen = DisplayInfo.preferredScreen(),
              let device = MTLCreateSystemDefaultDevice()
        else { throw RendererError.noDevice }

        guard let config else { throw RendererError.commandBuffer }
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        self.device = device
        let sessionID = SessionID()
        let timeBase = SessionTimeBase(clock: clock)
        self.sessionID = sessionID
        self.timeBase = timeBase
        nextSegmentIndex = 0
        nextLayoutIndex = 0
        nextSeqValue = 0
        staticToken = 0
        submittedCount = 0
        presentedCount = 0
        unconfirmedCount = 0
        currentSegment = nil

        let manifest = SessionManifest(
            sessionID: sessionID,
            sourceDeviceID: SessionController.hardwareModel(),
            appID: Bundle.main.bundleIdentifier ?? "dev.lumaphase.Lumaphase",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            osVersion: SessionController.osVersion(),
            osBuild: SessionController.osBuild(),
            timeOrigin: timeBase
        )
        let package = try SessionPackage(root: config.outputDirectory, manifest: manifest,
                                         timeBase: timeBase, clock: clock)
        if let profile = config.importedProfile {
            try package.addProfile(profile)
        }
        let recorder = PresentationRecorder(
            sessionID: sessionID,
            timeBase: timeBase,
            displayLog: package.displayLog,
            eventWriter: package.eventWriter,
            clock: clock
        )
        self.package = package
        self.recorder = recorder

        let info = DisplayInspector.info(for: screen)
        currentScreen = screen
        let window = DisplayWindowController(
            screen: screen,
            windowed: effectiveWindowed,
            verification: isSmoke,
            device: device
        )
        displayWindow = window
        fullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFullscreenExit() }
        }
        let driver = try FrameDriver(
            view: window.hostView,
            device: device,
            recorder: recorder,
            clock: clock,
            surfaceInstanceID: window.surfaceInstanceID
        )
        driver.allocateRenderSeq = { [weak self] in self?.allocateRenderSeq() }
        driver.onOverflow = { [weak self] in self?.handleOverflow() }
        driver.onSurfaceMismatch = { [weak self] size in self?.handleSurfaceMismatch(size) }
        driver.setPreferredRefresh(config.profile.requestedRefresh)
        driver.start()
        self.driver = driver

        sessionText = sessionID.description
        state = .preparing
        runStartRaw = clock.rawNanoseconds()
        startTimer()
        statusText = config.profile == .mCal
            ? "准备标定播放（M-CAL）。"
            : "准备显示，等待窗口与 drawable 尺寸稳定。"
    }

    private func allocateRenderSeq() -> RenderSeq? {
        let seq = RenderSeq(nextSeqValue)
        guard nextSeqValue < UInt64.max else {
            statusText = "render_seq 到达 UInt64 上限，会话结束。"
            return nil
        }
        nextSeqValue += 1
        return seq
    }

    func pauseOrResume() {
        switch state {
        case .running:
            pause(reason: .paused)
        case .paused:
            resume()
        default:
            break
        }
    }

    private func pause(reason: SegmentEndReason) {
        guard let driver, let writer = package?.eventWriter else { return }
        let now = clock.rawNanoseconds()
        pausedRemaining = max(1, runningDeadline - now)
        endSegment(reason)
        driver.setPlan(.held)
        driver.pause()
        writer.phaseChanged(from: .running, to: .paused, plannedDurationNanoseconds: nil)
        phase = .paused
        state = .paused
        canPause = false
        statusText = reason == .systemSleep
            ? "系统休眠：已结束当前段；唤醒后建立新段继续。"
            : "已暂停。恢复时建立新段并继续使用会话原点与递增序号。"
    }

    private func resume() {
        guard let driver, let writer = package?.eventWriter else {
            statusText = "恢复失败：会话已结束"
            return
        }
        do {
            let segment = try startSegment(reason: .resume)
            currentSegment = segment
            let now = clock.rawNanoseconds()
            driver.setPlan(.dynamic(segment))
            driver.setPreferredRefresh(config?.profile.requestedRefresh)
            driver.resume()
            runningDeadline = now + pausedRemaining
            writer.phaseChanged(from: .paused, to: .running, plannedDurationNanoseconds: pausedRemaining)
            phase = .running
            state = .running
            canPause = true
            pausedBySystem = false
            statusText = "已恢复：新段 \(segment.config.segmentID)，新布局 \(segment.layout.layoutID)。"
        } catch {
            abortActiveSession("恢复失败：\(error)")
        }
    }

    func stop() {
        switch state {
        case .idle, .finished:
            closePreview()
            completeQuit(true)
        case .draining:
            return
        case .preparing, .warmup, .sessionCard, .running, .endCard, .paused, .calibrating:
            closeReason = .userStop
            beginDrain()
        }
    }

    /// Normal Cmd-Q / menu quit. The app replies `terminateLater` and this
    /// finishes the active session through the normal stop/export path.
    func requestQuit(completion: @escaping (Bool) -> Void) {
        if state == .idle || state == .finished || package == nil {
            completion(true)
            return
        }
        quitCompletion = completion
        stop()
    }

    private func completeQuit(_ ok: Bool) {
        guard let completion = quitCompletion else { return }
        quitCompletion = nil
        if exportFailed {
            FileHandle.standardError.write(Data("Lumaphase: quit after an incomplete export — \(statusText)\n".utf8))
        }
        completion(ok)
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(30), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = clock.rawNanoseconds()
        updateStatus(now)
        // A surface change detected by the driver or a window notification is
        // handled on the next control tick, when the drawable size is settled.
        if restartPending, let driver, currentSegment != nil {
            let size = driver.drawableSize
            if size.width > 100, size.height > 100 {
                restartPending = false
                let reason = pendingEndReason
                pendingEndReason = .configurationChanged
                rebuildSegment(endReason: reason)
            }
        }
        switch state {
        case .preparing:
            guard let driver, driver.drawableSize.width > 100, driver.drawableSize.height > 100 else { return }
            let fullscreenReady = effectiveWindowed || displayWindow?.isFullscreen == true
            guard fullscreenReady || now - runStartRaw > 2_500_000_000 else { return }
            // Wait for the drawable size to settle so the fullscreen animation
            // cannot create a throw-away first segment.
            if let previous = preparingSize, previous == driver.drawableSize {
                if preparingSettledAt == 0 { preparingSettledAt = now; return }
                guard now - preparingSettledAt > 250_000_000 else { return }
                preparingSize = nil
                preparingSettledAt = 0
                beginWarmup()
            } else {
                preparingSize = driver.drawableSize
                preparingSettledAt = 0
            }
        case .warmup:
            guard now >= phaseDeadline else { return }
            enterSessionCard()
        case .sessionCard:
            guard now >= phaseDeadline else { return }
            enterRunning()
        case .running:
            handleSmoke(now)
            guard state == .running, now >= runningDeadline else { return }
            enterEndCard()
        case .endCard:
            guard now >= phaseDeadline else { return }
            beginDrain()
        case .draining:
            guard now >= phaseDeadline else { return }
            finishSession()
        case .paused:
            if isSmoke, smokeResumeAt > 0, now >= smokeResumeAt {
                smokeResumeAt = 0
                resume()
            }
        case .calibrating:
            advanceCalibration(now)
        case .idle, .finished:
            return
        }
    }

    private func updateStatus(_ now: Int64) {
        guard now - lastStatusUpdate > 200_000_000 else { return }
        lastStatusUpdate = now
        if let recorder {
            let stats = recorder.statistics()
            submittedCount = stats.segments.reduce(0) { $0 + $1.submitted }
            presentedCount = stats.segments.reduce(0) { $0 + $1.presented }
            unconfirmedCount = stats.segments.reduce(0) { $0 + $1.unconfirmed }
        }
        switch state {
        case .warmup, .sessionCard, .running, .endCard, .calibrating, .paused:
            checkDisplayChange(now)
        default:
            break
        }
    }

    // MARK: - Phases

    private func phaseDurations() -> (warmup: Int64, card: Int64, running: Int64, endCard: Int64) {
        if isSmoke {
            let phases = options.smokePhases
            return (
                Int64(phases.warmup * 1_000_000_000),
                Int64(phases.card * 1_000_000_000),
                Int64(phases.running * 1_000_000_000),
                Int64(phases.endCard * 1_000_000_000)
            )
        }
        return (
            10 * 1_000_000_000,
            2 * 1_000_000_000,
            config?.runningNanoseconds ?? Int64(max(1, runningSeconds) * 1_000_000_000),
            2 * 1_000_000_000
        )
    }

    private func beginWarmup() {
        guard let driver, let writer = package?.eventWriter else { return }
        if config?.profile == .mCal {
            beginCalibration()
            return
        }
        do {
            let segment = try startSegment(reason: .sessionStart)
            currentSegment = segment
            let durations = phaseDurations()
            let now = clock.rawNanoseconds()
            phaseDeadline = now + durations.warmup
            runStartRaw = now
            writer.phaseChanged(from: .configured, to: .warmup, plannedDurationNanoseconds: durations.warmup)
            issueWarmupPlan(segment)
            phase = .warmup
            state = .warmup
            canPause = false
            statusText = "预热 \(durations.warmup / 1_000_000_000) s；动态序号尚未消耗。"
            _ = driver
        } catch {
            fail("预热启动失败：\(error)")
        }
    }

    private func issueWarmupPlan(_ segment: FrozenSegment) {
        guard let driver else { return }
        let text = makeCardText(segment: segment, lines: [
            "OPTC-1  \(config?.profile.rawValue ?? profile.rawValue)",
            "WARMUP  \(config?.geometryProfile.rawValue ?? geometryProfile.rawValue)  请求 \(requestedRefreshText)"
        ])
        driver.setPlan(.card(segment, kind: .warmup, phase: .warmup, text: text, token: nextToken()))
    }

    private func enterSessionCard() {
        guard let driver, let writer = package?.eventWriter, let segment = currentSegment else { return }
        let durations = phaseDurations()
        let now = clock.rawNanoseconds()
        phaseDeadline = now + durations.card
        writer.phaseChanged(from: .warmup, to: .sessionCard, plannedDurationNanoseconds: durations.card)
        issueSessionCardPlan(segment)
        phase = .sessionCard
        state = .sessionCard
        statusText = "会话卡 2 s，完整 UUID 已显示。"
        _ = driver
    }

    private func issueSessionCardPlan(_ segment: FrozenSegment) {
        guard let driver else { return }
        let text = makeCardText(segment: segment, lines: [
            "OPTC-1  MACOS  START",
            sessionID?.description ?? "",
            "\(config?.profile.rawValue ?? profile.rawValue)  \(config?.geometryProfile.rawValue ?? geometryProfile.rawValue)  \(requestedRefreshText)"
        ])
        driver.setPlan(.card(segment, kind: .sessionCard, phase: .sessionCard, text: text, token: nextToken()))
    }

    private func enterRunning() {
        guard let driver, let writer = package?.eventWriter, let segment = currentSegment else { return }
        let durations = phaseDurations()
        let now = clock.rawNanoseconds()
        runningDeadline = now + durations.running
        writer.phaseChanged(from: .sessionCard, to: .running, plannedDurationNanoseconds: durations.running)
        driver.setPlan(.dynamic(segment))
        phase = .running
        state = .running
        canPause = true
        let actual = DisplayInspector.info(for: currentScreen ?? NSScreen.main!).refreshHz.map { String(format: "%.2f", $0) } ?? "未报告"
        statusText = "动态运行中：请求 \(requestedRefreshText)，系统模式 \(actual) Hz。"
        if isSmoke {
            if options.smokeResize {
                smokeResizeAt = now + 1_200_000_000
                smokeProgress = "将在 1.2 s 后改变窗口尺寸（新段）"
            }
            if options.smokePause {
                smokePauseAt = now + 1_000_000_000
                smokeProgress = "将在 1.0 s 后暂停、2.0 s 后恢复"
            }
        }
    }

    private func enterEndCard() {
        guard let driver, let writer = package?.eventWriter, let segment = currentSegment else { return }
        let durations = phaseDurations()
        let now = clock.rawNanoseconds()
        phaseDeadline = now + durations.endCard
        writer.phaseChanged(from: .running, to: .endCard, plannedDurationNanoseconds: durations.endCard)
        issueEndCardPlan(segment)
        phase = .endCard
        state = .endCard
        canPause = false
        statusText = "结束卡 2 s，随后最多 2 s 排空呈现结果。"
        _ = driver
    }

    private func issueEndCardPlan(_ segment: FrozenSegment) {
        guard let driver else { return }
        let text = makeCardText(segment: segment, lines: [
            "OPTC-1  MACOS  END",
            sessionID?.description ?? "",
            "\(config?.profile.rawValue ?? profile.rawValue)  \(config?.geometryProfile.rawValue ?? geometryProfile.rawValue)"
        ])
        driver.setPlan(.card(segment, kind: .endCard, phase: .endCard, text: text, token: nextToken()))
    }

    private func beginDrain() {
        guard let writer = package?.eventWriter else {
            completeQuit(true)
            return
        }
        if let segment = currentSegment {
            let reason: SegmentEndReason
            switch closeReason {
            case .normal: reason = .normalEnd
            case .userStop: reason = .userStop
            case .overflow: reason = .logOverflow
            case .renderFailure: reason = .renderFailure
            }
            writer.segmentEnded(segment.config.segmentID, reason: reason)
            currentSegment = nil
        }
        if phase.isDisplayPhase {
            writer.phaseChanged(from: phase, to: .export, plannedDurationNanoseconds: nil)
        }
        driver?.setPlan(.held)
        phase = .export
        state = .draining
        canPause = false
        phaseDeadline = clock.rawNanoseconds() + SessionClockDomain.presentationDrainTimeoutNanoseconds
        statusText = "排空呈现结果（最多 2 s）…"
    }

    private func finishSession() {
        guard let package, let recorder else {
            completeQuit(true)
            return
        }
        let now = clock.rawNanoseconds()
        let seal = recorder.seal(at: now)
        let statistics = recorder.statistics()
        let reason: SessionCloseReason
        switch closeReason {
        case .normal: reason = .normalEnd
        case .userStop: reason = .userStop
        case .overflow: reason = .logOverflow
        case .renderFailure: reason = .renderFailure
        }
        do {
            let directory = try package.finish(
                close: SessionClose(reason: reason, closedAtRawNanoseconds: now,
                                    pendingFrameCount: seal.pendingFrameCount),
                statistics: statistics,
                timing: recorder.timingStatistics()
            )
            exportPath = directory.path
            exportFailed = false
            let submitted = statistics.segments.reduce(0) { $0 + $1.submitted }
            if submitted == 0, reason == .userStop {
                statusText = "已取消：未产生任何帧，导出空会话 \(directory.path)（SESSION_CLOSED reason=USER_STOP）。"
            } else {
                statusText = "导出完成：\(directory.path)（未确认 \(seal.pendingFrameCount) 帧，迟到回调 \(seal.lateAfterSealCount)）"
            }
        } catch {
            exportFailed = true
            statusText = "导出失败：\(error)"
        }
        teardownDisplay()
        state = .finished
        stopTimer()
        isBusy = false
        phase = .idle
        if isSmoke {
            smokeProgress = ""
            print("EXPORT \(exportPath ?? "<failed>")")
            print("SUBMITTED \(submittedCount) PRESENTED \(presentedCount) UNCONFIRMED \(unconfirmedCount)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        }
        completeQuit(true)
    }

    /// Active-session failure (resume/segment rebuild): show the error, end the
    /// segment with RENDER_FAILURE and export instead of silently continuing.
    private func abortActiveSession(_ message: String) {
        statusText = message
        exportFailed = true
        if let package, let recorder {
            if let segment = currentSegment {
                package.eventWriter.segmentEnded(segment.config.segmentID, reason: .renderFailure)
                currentSegment = nil
            }
            package.eventWriter.renderFailure(identity: nil, segmentID: nil,
                                              operation: "session", errorCode: nil, message: message)
            if phase.isDisplayPhase {
                package.eventWriter.phaseChanged(from: phase, to: .export, plannedDurationNanoseconds: nil)
            }
            let now = clock.rawNanoseconds()
            let seal = recorder.seal(at: now)
            do {
                let directory = try package.finish(
                    close: SessionClose(reason: .renderFailure, closedAtRawNanoseconds: now,
                                        pendingFrameCount: seal.pendingFrameCount),
                    statistics: recorder.statistics(),
                    timing: recorder.timingStatistics()
                )
                exportPath = directory.path
                statusText = message + "；已导出 \(directory.path)"
            } catch {
                statusText = message + "；导出失败：\(error)"
            }
        }
        teardownDisplay()
        state = .finished
        stopTimer()
        isBusy = false
        phase = .idle
        completeQuit(true)
    }

    private func fail(_ message: String) {
        statusText = message
        exportFailed = true
        teardownDisplay()
        state = .idle
        stopTimer()
        isBusy = false
        completeQuit(true)
    }

    private func teardownDisplay() {
        if let observer = fullscreenObserver {
            NotificationCenter.default.removeObserver(observer)
            fullscreenObserver = nil
        }
        driver?.stop()
        driver = nil
        displayWindow?.close()
        displayWindow = nil
        restartPending = false
    }

    // MARK: - Segments

    private func startSegment(reason: SegmentStartReason, note: String? = nil) throws -> FrozenSegment {
        guard let package, let driver, let sessionID, let config else {
            throw RendererError.commandBuffer
        }
        let screen = displayWindow?.currentScreen ?? currentScreen ?? NSScreen.main!
        let info = DisplayInspector.info(for: screen)
        let size = driver.drawableSize
        let layout = try LayoutBuilder.make(
            layoutID: "layout-\(nextLayoutIndex)",
            geometryProfile: config.geometryProfile,
            drawable: size,
            rotationDeg: config.rotationDeg,
            levels: config.levels
        )
        nextLayoutIndex += 1
        let snapshot = DisplayInspector.snapshot(
            drawableSize: size,
            info: info,
            brightness: config.brightness,
            colorSpaceName: DisplayInspector.renderColorSpaceName,
            operatorNote: config.operatorNote
        )
        let segmentConfig = SegmentConfig(
            segmentID: SegmentID(nextSegmentIndex),
            layoutID: layout.layoutID,
            experimentProfile: config.profile,
            snapshot: snapshot,
            displayProfileID: config.importedProfile?.profileID,
            operatorNote: note ?? config.operatorNote
        )
        nextSegmentIndex += 1
        try package.addLayout(layout)
        try package.addSegment(segmentConfig)
        package.eventWriter.segmentStarted(segmentConfig, reason: reason)
        currentScreen = screen
        displaySignature = displaySignatureFor(info: info, size: size)
        return FrozenSegment(sessionID: sessionID, config: segmentConfig, layout: layout,
                             surfaceInstanceID: displayWindow?.surfaceInstanceID ?? "")
    }

    private func endSegment(_ reason: SegmentEndReason) {
        guard let writer = package?.eventWriter, let segment = currentSegment else { return }
        writer.segmentEnded(segment.config.segmentID, reason: reason)
        currentSegment = nil
    }

    private func handleOverflow() {
        guard state == .running || state == .calibrating || state == .paused else { return }
        closeReason = .overflow
        statusText = "日志溢出：停止新动态状态并准备导出不完整会话。"
        if let segment = currentSegment, let writer = package?.eventWriter {
            writer.segmentEnded(segment.config.segmentID, reason: .logOverflow)
            currentSegment = nil
        }
        beginDrain()
    }

    private func displaySignatureFor(info: DisplayInfo, size: PixelSize) -> String {
        "\(info.modeID ?? "-")|\(info.maximumFramesPerSecond)|\(size.width)x\(size.height)|\(info.displayID)"
    }

    private func checkDisplayChange(_ now: Int64) {
        guard now - lastDisplayCheck > 500_000_000 else { return }
        lastDisplayCheck = now
        guard let driver, let window = displayWindow else { return }
        let size = driver.drawableSize
        let screen = window.currentScreen ?? currentScreen
        guard size.width > 100, size.height > 100 else { return }
        let info = DisplayInspector.info(for: screen ?? NSScreen.main!)
        let signature = displaySignatureFor(info: info, size: size)
        guard signature != displaySignature else { return }
        let sizeChanged = currentSegment.map { $0.layout.drawableSize != size } ?? false
        let screenChanged = screen != currentScreen
        displaySignature = signature
        currentScreen = screen
        switch state {
        case .paused:
            // No segment exists while paused; resume builds the new pair.
            statusText = "暂停中检测到显示配置变化；恢复时将建立新段。"
            return
        case .warmup, .sessionCard, .running, .endCard, .calibrating:
            let reason: SegmentEndReason
            if pendingEndReason != .configurationChanged {
                reason = pendingEndReason
            } else if sizeChanged {
                reason = .surfaceChanged
            } else if screenChanged {
                reason = .displayChanged
            } else {
                reason = .configurationChanged
            }
            pendingEndReason = .configurationChanged
            rebuildSegment(endReason: reason)
        default:
            return
        }
    }

    /// Closes the current segment and re-issues the plan of the current phase
    /// with a layout built from the real drawable size.
    private func rebuildSegment(endReason: SegmentEndReason) {
        guard let driver, let writer = package?.eventWriter else { return }
        restartPending = false
        pendingEndReason = .configurationChanged
        if let segment = currentSegment {
            writer.segmentEnded(segment.config.segmentID, reason: endReason)
            currentSegment = nil
        }
        do {
            let startReason: SegmentStartReason = nextSegmentIndex == 0 ? .sessionStart : .configurationChanged
            let segment = try startSegment(reason: startReason)
            currentSegment = segment
            issueCurrentPhasePlan(segment)
            statusText = "显示配置变化（\(endReason.rawValue)）：新段 \(segment.config.segmentID)，新布局 \(segment.layout.layoutID)。"
            _ = driver
        } catch {
            abortActiveSession("配置变化后重建段失败：\(error)")
        }
    }

    private func issueCurrentPhasePlan(_ segment: FrozenSegment) {
        guard let driver else { return }
        switch state {
        case .warmup:
            issueWarmupPlan(segment)
        case .sessionCard:
            issueSessionCardPlan(segment)
        case .running:
            driver.setPlan(.dynamic(segment))
        case .endCard:
            issueEndCardPlan(segment)
        case .calibrating:
            if calibrationIndex < calibrationSteps.count {
                let step = calibrationSteps[calibrationIndex]
                driver.setPlan(.calibration(segment, screen: step.screen, token: nextToken()))
                calibrationFlipAt = clock.rawNanoseconds() + 1_000_000_000
            }
        default:
            break
        }
    }

    private func handleSurfaceMismatch(_ actual: PixelSize) {
        switch state {
        case .warmup, .sessionCard, .running, .endCard, .calibrating:
            if pendingEndReason != .fullscreenExit {
                pendingEndReason = .surfaceChanged
            }
            restartPending = true
            statusText = "drawable 尺寸 \(actual.width)×\(actual.height) 与当前布局不一致，切换新段…"
        default:
            break
        }
    }

    private func handleFullscreenExit() {
        switch state {
        case .warmup, .sessionCard, .running, .endCard, .calibrating:
            pendingEndReason = .fullscreenExit
            restartPending = true
            driver?.setPlan(.held)
            statusText = "已退出全屏：结束旧段，按新尺寸重建。"
        default:
            break
        }
    }

    private func handleSleep() {
        if state == .running {
            pausedBySystem = true
            pause(reason: .systemSleep)
            return
        }
        guard currentSegment != nil else { return }
        pausedBySystem = true
        endSegment(.systemSleep)
        driver?.setPlan(.held)
        driver?.pause()
        statusText = "系统休眠：已结束当前段，唤醒后重建。"
    }

    private func handleWake() {
        guard pausedBySystem else { return }
        pausedBySystem = false
        if state == .paused {
            resume()
            return
        }
        driver?.resume()
        if currentSegment == nil {
            rebuildSegment(endReason: .systemSleep)
        }
    }

    // MARK: - Smoke drivers

    private func handleSmoke(_ now: Int64) {
        if options.smokeResize, !smokeResizeDone, smokeResizeAt > 0, now >= smokeResizeAt {
            smokeResizeDone = true
            displayWindow?.resizeForSmoke()
            statusText = "Smoke：窗口尺寸改变，等待新段。"
        }
        if options.smokePause, !smokePauseDone, smokePauseAt > 0, now >= smokePauseAt {
            smokePauseDone = true
            pauseOrResume()
            smokeResumeAt = now + 1_000_000_000
            statusText = "Smoke：暂停；1 s 后自动恢复。"
        }
    }

    // MARK: - Calibration playback

    func startCalibration() {
        guard !isBusy else { return }
        profile = .mCal
        start()
    }

    private func beginCalibration() {
        guard let writer = package?.eventWriter else { return }
        calibrationSteps = []
        let frozen = config
        if frozen?.calibrationGeometry ?? calibrationGeometry {
            calibrationSteps.append((5 * 1_000_000_000,
                .geometry(moduleCount: (frozen?.geometryProfile.layoutProfile ?? geometryProfile.layoutProfile).moduleCount),
                "CALIBRATION geometry: ArUco markers + 1px module boundaries; module indices are in layout.json"))
        }
        if frozen?.calibrationStaircase ?? calibrationStaircase {
            calibrationSteps.append((8 * 1_000_000_000,
                .staircase(levels: [0, 36, 73, 109, 146, 182, 219, 255]),
                "CALIBRATION staircase: 8 equal-width vertical bands, code values 0,36,73,109,146,182,219,255 left to right"))
        }
        if frozen?.calibrationFlipEnabled ?? calibrationFlip {
            calibrationSteps.append((6 * 1_000_000_000, .complementary(flip: false),
                "CALIBRATION complementary flip: alternating [L,H]/[H,L] module columns; flipping every 1 s"))
        }
        guard !calibrationSteps.isEmpty else {
            statusText = "没有选择任何标定阶段。"
            teardownDisplay()
            state = .idle
            isBusy = false
            stopTimer()
            return
        }
        calibrationIndex = 0
        calibrationFlipState = false
        phase = .calibration
        state = .calibrating
        writer.phaseChanged(from: .configured, to: .calibration, plannedDurationNanoseconds: nil)
        startCalibrationStep()
    }

    private func startCalibrationStep() {
        guard let driver else { return }
        guard calibrationIndex < calibrationSteps.count else {
            driver.setPlan(.held)
            beginDrain()
            return
        }
        let step = calibrationSteps[calibrationIndex]
        do {
            let reason: SegmentStartReason = nextSegmentIndex == 0 ? .sessionStart : .configurationChanged
            let segment = try startSegment(reason: reason, note: step.note)
            currentSegment = segment
            let now = clock.rawNanoseconds()
            calibrationStepDeadline = now + step.duration
            calibrationFlipAt = now + 1_000_000_000
            calibrationFlipState = false
            driver.setPlan(.calibration(segment, screen: step.screen, token: nextToken()))
            statusText = "标定阶段 \(calibrationIndex + 1)/\(calibrationSteps.count)：\(step.note)"
        } catch {
            fail("标定段创建失败：\(error)")
        }
    }

    private func advanceCalibration(_ now: Int64) {
        guard calibrationIndex < calibrationSteps.count else { return }
        let step = calibrationSteps[calibrationIndex]
        if case .complementary = step.screen, calibrationFlipAt > 0, now >= calibrationFlipAt {
            calibrationFlipState.toggle()
            calibrationFlipAt = now + 1_000_000_000
            if let driver, let segment = currentSegment {
                driver.setPlan(.calibration(segment, screen: .complementary(flip: calibrationFlipState),
                                            token: nextToken()))
            }
        }
        guard now >= calibrationStepDeadline else { return }
        if let writer = package?.eventWriter, let segment = currentSegment {
            writer.segmentEnded(segment.config.segmentID, reason: .normalEnd)
            currentSegment = nil
        }
        calibrationIndex += 1
        startCalibrationStep()
    }

    // MARK: - Helpers

    private func nextToken() -> Int {
        staticToken += 1
        return staticToken
    }

    private func makeCardText(segment: FrozenSegment, lines: [String]) -> CardText? {
        guard let device else { return nil }
        let rect = SceneBuilder.patternTextRect(segment.layout)
        return CardTextRenderer.make(
            device: device,
            lines: lines,
            pixelSize: PixelSize(width: max(64, rect.width), height: max(32, rect.height))
        )
    }

    private var requestedRefreshText: String {
        (config?.profile ?? profile).requestedRefresh.map { String(format: "%.2f Hz", $0.hertz) } ?? "未请求"
    }

    // MARK: - System facts (public APIs only)

    static func hardwareModel() -> String {
        sysctlString("hw.model") ?? "unknown-mac"
    }

    static func osBuild() -> String {
        sysctlString("kern.osversion") ?? "unknown"
    }

    static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func defaultOutputDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Lumaphase", isDirectory: true)
    }
}
