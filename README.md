# Lumaphase

Lumaphase 是用于多双目相机光学对时实验的 macOS 显示应用。它在屏幕上生成 `OPTC-1` 时间码，并记录每张图案的提交与系统呈现时间，供识别后端关联相机图像、估计曝光时间差。

应用提供 F68-G6x12（默认）和 C52-G5x12 网格布局，保留原 F68/C52 单排，并提供四角 ArUco 定位标记、标定图案播放和会话数据导出。Mac 与 Android 显示端共用编码协议和文件格式；相机采集、图像解码、屏幕模型拟合和设备时钟映射由外部组件完成。

当前实现已完成本机 Metal 显示与会话导出验证，光学对时精度尚未经过相机和光电测量验收。

## 从源码构建

运行需要 Apple Silicon Mac、macOS 14 或更新版本，以及支持 Metal 的显示设备；不支持 Intel Mac。源码构建需要提供 macOS SDK 的 Xcode 工具链和 Swift 6.0 或更新版本；Python 3 仅用于校验导出文件。Swift Package 没有外部包依赖。

在仓库根目录执行：

```sh
bash Scripts/bundle.sh debug
```

脚本编译应用、生成 `.build/Lumaphase.app`，并执行本地 ad-hoc 签名；成功后打印应用路径，签名失败时退出。构建过程不会打开窗口。

若旧版本仍在运行，使用另一个输出目录，避免覆盖正在使用的应用包：

```sh
bash Scripts/bundle.sh debug .build/verified/Lumaphase.app
```

首个参数也可用 `release`。打包脚本固定构建 arm64，不生成 Intel 或通用二进制。

## Tag 发布

[发布 workflow](.github/workflows/release.yml) 只在推送 `v*` tag 时触发，普通分支 push 不运行。版本名使用 `v1.2.3`；预发布版本可用 `v1.2.3-rc.1`。workflow 在 Apple Silicon runner 上运行测试、编译 release 应用，再创建 GitHub Release，上传 `Lumaphase-<tag>-macOS-arm64.zip`。带预发布后缀的 tag 会创建 prerelease。

应用版本取 tag 的数字部分，构建号取 Actions 运行编号。发布包使用 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。发布过程不启动应用窗口。

## 完成第一次采集

以下步骤使用默认输出路径构建的应用包。打开应用会显示设置窗口；开始实验后默认进入原生全屏。

```sh
open .build/Lumaphase.app
```

1. 在系统显示设置中选择实验需要的刷新模式，并固定亮度和色彩设置。应用会分别显示请求刷新率与系统报告值，不能用请求值判断模式已生效。
2. 在应用中选择配置 `M59-S1`，保留默认 F68-G6x12、0° 旋转、低灰度 32、高灰度 224 和动态时长 90 s。选择输出目录；默认是 `~/Documents/Lumaphase`。
3. 选择**预览**，确认目标屏幕能显示完整条码和四角标记。预览不创建会话，也不导出日志。
4. 在外部采集控制器中设置相机帧率、曝光和硬件同步，启动图像与硬件时间戳记录。应用不会设置或触发相机；预热和会话卡不参加对时误差统计。
5. 选择**开始**。应用依次显示 10 s 预热、2 s 会话卡、90 s 动态编码和 2 s 结束卡，再等待最多 2 s 收集剩余呈现结果。
6. 记录会话卡上的完整 UUID，将相机数据与该会话关联。应用结束后回到设置窗口，状态区显示导出目录、已提交帧数、已确认呈现帧数和未确认帧数。

运行期间，**暂停**结束当前采集段；**恢复**建立新段，并继续递增状态序号。选择**停止并导出**可提前结束会话。运行或暂停期间可切换布局：运行时结束当前段并建立新段，暂停时在恢复后生效，旧布局保留，动态序号不重置。其他设置在会话期间锁定；需要改变实验配置或导入标定时，先结束当前会话。

## 实验配置

相机条件由外部采集控制器设置。选择配置名不会改变相机曝光，也不保证系统采用请求的刷新率。

| 配置 | 显示刷新请求 | 外部相机条件 | 用途 |
| --- | --- | --- | --- |
| `M59-S1`（默认） | 60000/1001 Hz，约 59.94 Hz | 30 Hz、1 ms 曝光 | 主实验 |
| `M120-S1` | 120 Hz | 30 Hz、1 ms 曝光 | 高刷新率对比实验 |
| `M59-E20` | 约 59.94 Hz | 30 Hz、20 ms 曝光 | 独立长曝光积分实验 |
| `M-CAL` | 不指定，由标定任务选择显示模式 | 由标定采集任务指定 | 独立几何、灰度和发光时序标定 |

普通动态实验默认运行 90 s；选择 **20 min** 可进行长时间漂移实验。C52 比 F68 少循环指示区，适合条码成像宽度较小的场景；两种布局都保留 16 位 Gray 序号和 CRC。

选择 `M-CAL` 或**播放标定（M-CAL）**，可播放所选的几何、灰度阶梯和互补翻转图案。各图案阶段单独分段，不消耗动态序号。应用只呈现并记录图案，标定参数由外部程序拟合。

如已有屏幕标定，可在开始会话前选择**导入标定 JSON…**。输入对象需包含 `profile_id`、`calibration_key` 和 `model`；字段定义见[共享契约的标定章节](docs/cw/optc-1-contract.md#9-缺失标定和配置匹配)。新标定键包含 `geometry_profile`。旧标定缺该字段仍可导入，但保持 `IMPORTED_UNVERIFIED`，不能自动判定网格兼容；应用不解释模型来推断跨布局可用性。`model` 按 JSON 值保留，不保留原文件空白和键顺序。未导入标定也可显示、记录和导出，文件中会明确标记 `MISSING`。

## 导出与校验

新会话使用文件 schema 1.1，光学协议仍为 OPTC-1；校验器保留 1.0 原单排读取支持。每个会话保存到 `session_<uuid>/`。其中 `<uuid>` 是本次会话的完整 UUID。

```text
session_<uuid>/
├── manifest.json
├── layout.json
├── display_events.jsonl
├── configuration_events.jsonl
├── display_profile.json
└── session_summary.json
```

| 文件 | 内容 |
| --- | --- |
| `manifest.json` | 会话、时钟原点、应用与系统信息，以及各段配置 |
| `layout.json` | 各段引用的实际像素布局、模块矩形、旋转与定位标记 |
| `display_events.jsonl` | 逐帧提交、确认呈现和未确认事件 |
| `configuration_events.jsonl` | 阶段切换、采集段起止、错误、溢出与封存事件 |
| `display_profile.json` | 被引用的标定对象及逐段匹配状态；缺失标定时仍存在 |
| `session_summary.json` | 帧数、完整性状态，以及 GPU、呈现延迟和呈现间隔统计 |

未确认帧数大于 0 不等于日志丢失。`UNCONFIRMED` 表示没有取得有效的实际呈现证据；`INCOMPLETE` 表示数据完整性受损，例如发生日志溢出。只有预计呈现时间时，应用不会将它填入实际呈现字段。时间和事件关联的完整定义见[共享契约](docs/cw/optc-1-contract.md)。

将下面的路径替换为状态区显示的实际会话目录，再运行校验器：

```sh
python3 Scripts/validate_session.py /path/to/session_<uuid>
```

校验器检查 JSON 类型、时间原点换算、编码载荷、布局、提交与呈现的关联、摘要计数及完整性状态。通过时打印 `OK … checks` 并返回退出码 0；失败时打印 `FAIL …` 并返回非零退出码。检查已知不完整的数据包时，可加 `--allow-incomplete`；此时跳过完整包的摘要一致性检查，仍检查前面的文件结构和事件字段。

## 命令行与开发验证

命令行参数可预设设置窗口；只有 `--auto-start` 或 `--smoke` 会自动开始会话。以下命令仅打印帮助，不打开窗口：

```sh
.build/Lumaphase.app/Contents/MacOS/Lumaphase --help
```

例如，在窗口模式下自动运行一个 3 s 动态实验，并将会话写入指定目录：

```sh
.build/Lumaphase.app/Contents/MacOS/Lumaphase \
  --windowed --auto-start --profile M59-S1 --layout F68 \
  --rotation 0 --duration 3 --output /tmp/lumaphase-sessions
```

`--duration` 只改变动态阶段，仍保留正常的预热和会话卡时长。`--layout` 支持 F68-G6x12、C52-G5x12 和原 F68/C52，`--rotation` 支持 0/90/180/270；完整参数以 `--help` 为准。

**`--smoke` 会自动打开覆盖屏幕的高层级窗口，短时运行后导出并退出，会干扰前台工作。** 需要自动检查尺寸变化或暂停恢复时，可与 `--smoke-resize`、`--smoke-pause` 一起使用。这些参数用于主动发起的显示测试，不是无界面测试。

不打开应用窗口的测试命令为：

```sh
swift test --jobs 4
```

测试覆盖协议向量、65536 个载荷、UInt64 边界、布局旋转、事件时序、日志溢出和封存。离屏 Metal 测试读回低灰度 32、高灰度 224、黑边 0 和白色静区 255；无 Metal 设备时该项跳过。

## 验证范围

已在 Apple Silicon、Xcode 27.2 / Swift 6.4.2 环境通过原测试和 CR-001 网格测试，包括共同 placement fixture、全载荷重排、四旋转及数据/填充的离屏 Metal 码值回读。原单排版本运行过真实 Metal 会话，验证正常全屏采集、暂停恢复、尺寸变化、C52 旋转、标定播放和六文件导出；本次网格版本未打开前台窗口，几何切换 UI 和真实屏幕呈现尚未重跑。macOS 14 是部署目标，尚未在该系统版本实机验证。

本机公开接口当前只报告约 60 Hz，59.94 Hz 和 120 Hz 实验模式尚未验证。最近补充的退出封存、休眠唤醒和全屏退出修订经过编译与代码复核，未重新运行前台测试。相机实拍识别率、光电时间精度和 20 min 长时稳定性仍待独立实验。

离屏数字码值正确不代表面板实际发光时序已知。屏幕标定需与实际显示模式、亮度、色彩配置和布局匹配；缺少匹配标定时，不能据此声称达到微秒级对时精度。

## 文档与许可证

- [OPTC-1 共享契约](docs/cw/optc-1-contract.md)：编码、坐标、时间字段、事件和导出格式。
- [macOS 设计说明](docs/cw/macos-design.md)：平台实现方案与验证依据。

作者：DengQi。项目代码采用 [MIT](LICENSE) 许可证。内置 ArUco 标记数据取自 OpenCV 4.10.0，来源记录在 [third_party/opencv-4.10.0](third_party/opencv-4.10.0/aruco-4x4-50-first4.json)，按其 [Apache-2.0 许可证](third_party/opencv-4.10.0/LICENSE) 保留。
