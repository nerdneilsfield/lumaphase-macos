import SwiftUI
import OpticCore
import OpticDisplay

struct SettingsView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Group {
                    experimentSection.disabled(controller.isBusy)
                    patternSection
                    timelineSection.disabled(controller.isBusy)
                    calibrationSection.disabled(controller.isBusy)
                }
                displaySection
                cr002Actions
                actions
                statusSection
            }
            .padding(20)
        }
        .frame(minWidth: 700, idealWidth: 740, minHeight: 760)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lumaphase · OPTC-1 显示端")
                .font(.title2).bold()
            Text("F68/C52 光学图案、逐帧呈现证据与会话导出。相机采集与屏幕模型拟合不在本应用内。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var experimentSection: some View {
        GroupBox("实验配置") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("配置", selection: $controller.profile) {
                        ForEach(ExperimentProfile.presets, id: \.rawValue) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .frame(width: 220)
                    Text(profileHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("请求刷新")
                    Text(controller.profile.requestedRefresh.map { String(format: "%.2f Hz", $0.hertz) } ?? "未请求（M-CAL）")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text("实际刷新以系统模式为准，不通过回调频率宣称锁定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("人工亮度（0–1，可空）")
                    TextField("如 0.5", text: $controller.brightnessText)
                        .frame(width: 90)
                    Text("备注")
                    TextField("操作员记录", text: $controller.operatorNote)
                }
                .textFieldStyle(.roundedBorder)
                Text("macOS 无公开 API 读取亮度、True Tone、Night Shift 或 HDR 开关；这些字段导出为 null/UNKNOWN，仅记录人工值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var patternSection: some View {
        GroupBox("图案与几何") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    Picker("布局", selection: Binding(get: { controller.geometryProfile },
                                                       set: { controller.changeGeometry($0) })) {
                        ForEach(GeometryProfile.macOSCases, id: \.rawValue) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }
                    .frame(width: 180)
                    .disabled(!controller.canChangeGeometry)
                    Picker("图案旋转", selection: $controller.rotationDeg) {
                        ForEach([0, 90, 180, 270], id: \.self) { degrees in
                            Text("\(degrees)°").tag(degrees)
                        }
                    }
                    .frame(width: 150)
                    .disabled(controller.isBusy)
                }
                HStack(spacing: 18) {
                    Stepper("L = \(controller.lowLevel)", value: $controller.lowLevel, in: 0...255)
                    Stepper("H = \(controller.highLevel)", value: $controller.highLevel, in: 0...255)
                    Text("8-bit SDR 码值，默认 32/224")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(controller.isBusy)
                HStack {
                    Toggle("窗口模式（不进入全屏）", isOn: $controller.windowed)
                    Spacer()
                    Text("ArUco DICT_4X4_50 ID 0–3，OpenCV 4.10.0 固定字节")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(controller.isBusy)
            }
            .padding(6)
        }
    }

    private var timelineSection: some View {
        GroupBox("时间线与输出") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RUNNING 时长（秒）")
                    TextField("90", value: $controller.runningSeconds, format: .number)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                    Button("90 s") { controller.runningSeconds = 90 }
                    Button("20 min") { controller.runningSeconds = 1200 }
                    Spacer()
                    Text("预热 10 s · 会话卡 2 s · 结束卡 2 s · 排空 ≤2 s")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("输出目录")
                    Text(controller.outputDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…") { controller.chooseOutputDirectory() }
                }
            }
            .padding(6)
        }
    }

    private var calibrationSection: some View {
        GroupBox("标定导入与播放") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("导入标定 JSON…") { controller.importCalibration() }
                    Button("清除") { controller.clearCalibration() }
                        .disabled(controller.importedProfileID == nil)
                    Text(controller.importedProfileStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("导入的 model 作为不透明对象原样写入 display_profile.json；本应用不做任何拟合或匹配判定之外的推断。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Toggle("几何", isOn: $controller.calibrationGeometry)
                    Toggle("灰度阶梯", isOn: $controller.calibrationStaircase)
                    Toggle("互补翻转", isOn: $controller.calibrationFlip)
                }
                Toggle("普通 RUN 前先显示大 Tag 定位（同一窗口，需人工继续）", isOn: $controller.largeTagInitialization)
                Text("会话中隐藏设置窗口。外部相机逐路核对至少100个唯一有效帧后，按 ⌘Return 继续；显示端不会自动判定通过。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("播放标定（M-CAL）") { controller.startCalibration() }
                        .disabled(controller.isBusy)
                    Text("所选阶段各自建立独立段并逐帧记录呈现证据；不消耗动态序号")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var displaySection: some View {
        GroupBox("显示器与渲染表面") {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.displayInfoText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("重新读取") { controller.refreshDisplayInfo() }
                    Text("target_present = Update.targetPresentationTimestamp · deadline = Update.targetTimestamp（固定来源）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var cr002Actions: some View {
        GroupBox("CR-002 定位与颜色诊断") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("静态诊断 A（独立会话）") { controller.start(mode: .staticA) }
                    Button("VSync 黑白 B · 60s（独立会话）") { controller.start(mode: .dynamicBW) }
                }
                .disabled(controller.isBusy)
                Text("A：白/黑/2×2 棋盘，各稳定1s、计划采样3s；B沿用所选实验的刷新请求。会话中设置窗口隐藏，⌘. 停止并导出。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("已核对外部相机定位，继续 RUN") { controller.continueAfterLargeTags() }
                    .disabled(!controller.awaitingGeometryConfirmation)
            }
            .padding(6)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("预览") { controller.preview() }
                .disabled(controller.isBusy)
            Button("开始") { controller.start(mode: DiagnosticSessionMode.none) }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(controller.isBusy)
            Button(controller.canPause ? "暂停" : "恢复") { controller.pauseOrResume() }
                .disabled(!controller.canPause && controller.phase != .paused)
            Button("停止并导出") { controller.stop() }
                .disabled(controller.isBusy == false && controller.exportPath == nil && controller.phase == .idle)
            Spacer()
            if !controller.smokeProgress.isEmpty {
                Text(controller.smokeProgress).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusSection: some View {
        GroupBox("状态") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    Text("阶段：\(controller.phase.rawValue)")
                    Text("已提交：\(controller.submittedCount)")
                    Text("已确认呈现：\(controller.presentedCount)")
                    Text("最终未确认：\(controller.unconfirmedCount)")
                }
                .font(.system(.callout, design: .monospaced))
                Text("会话：\(controller.sessionText)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(controller.statusText)
                    .font(.callout)
                    .foregroundStyle(controller.exportFailed ? .red : .primary)
                if let exportPath = controller.exportPath {
                    Text("导出目录：\(exportPath)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var profileHint: String {
        switch controller.profile {
        case .m59S1: return "固定 59.94 Hz 请求；相机 30 Hz / 1 ms 曝光（外部）"
        case .m120S1: return "ProMotion 120 Hz 请求；记录实际模式与呈现间隔"
        case .m59E20: return "独立会话；相机 20 ms 曝光（外部）"
        case .mCal: return "独立会话；几何 / 灰度 / 互补翻转，不消耗动态序号"
        default: return "自定义配置"
        }
    }
}
