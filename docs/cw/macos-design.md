# macOS 光学时间码显示应用实现说明

状态：v1.0，未发布的文档设计，应用尚未实现。

日期：2026-11-10。
共享格式：[OPTC-1 显示端共享数据契约](optc-1-contract.md)，Android 与 macOS 已确认 v1.0，`schema_version="1.0"`。

Mac 应用负责生成确定性编码、显示图案、记录逐帧呈现证据，并导出可供识别后端重放的数据。曝光积分拟合、双目联合解码、设备时钟映射和相机触发调整由其他组件负责。本轮只新增 `docs/cw/` 文档，不创建工程或应用代码。

## 1. 目标配置和证据边界

原设计目标设备为 16 英寸 MacBook Pro、M5 Pro。主实验为固定 59.94 Hz 显示、相机 30 Hz、1 ms 曝光，动态段默认 90 s。漂移实验为 1200 s。相机曝光和硬件配对由采集控制器配置，Mac 应用只记录实验说明，不控制相机。

段快照的 `experiment_profile` 来自操作员在设置页选择的配置名，默认 `M59-S1`。以下预定义值来自原设计第 3 节；自定义配置使用自定义名称，并在 `operator_note` 说明显示设置、相机条件和用途。相机列表示外部采集控制器应采用的实验条件，不表示 Mac 已设置或核实相机。

| `experiment_profile` | 显示配置 | 相机实验条件 | 用途 |
| --- | --- | --- | --- |
| `M59-S1` | 固定 59.94 Hz，每次新动态提交更新编码 | 30 Hz、1 ms 曝光 | 主实验，估计固定曝光差 |
| `M120-S1` | ProMotion，请求 120 Hz，记录实际模式与呈现间隔 | 30 Hz、1 ms 曝光 | 刷新配置对比，使用实测扫描模型 |
| `M59-E20` | 固定 59.94 Hz | 30 Hz、20 ms 曝光 | 独立长曝光积分实验 |
| `M-CAL` | 由本次标定选择刷新模式 | 由外部标定采集任务指定 | 独立几何、灰度与发光时序标定 |

上述配置不替代显示模式和相机元数据。应用保存选择的实验名，实际显示模式仍取系统报告；相机曝光由调用方或采集记录提供。20 min 漂移实验通过运行时长表达，不增加同义配置名。

使用 Swift 管理应用，SwiftUI 提供设置界面，AppKit 管理原生窗口与 Metal 视图。光学图案使用 `CAMetalLayer`，由 `CAMetalDisplayLink` 驱动。最低系统暂定 macOS 14；Apple 文档标明该版本开始提供 `CAMetalDisplayLink`，因此本设计不增加旧系统调度实现。

用户在系统显示设置中选择固定 59.94 Hz。应用记录请求配置、系统当前模式和实际呈现间隔，不通过软件回调频率声称已锁定物理刷新率。原设计中 30 Hz 与 60000/1001 Hz 产生约 33.333 μs 相位步进的结果是理想频率算例，不能代替本机实测。

目前只验证了设计资料和部分 Apple API 文档，没有运行 Metal 显示链路、屏幕标定或相机实验。1 ms 与 100 μs 精度都需要后端和独立实验验证；本应用的日志分辨率不构成光学精度证明。

## 2. 组件与数据所有权

先按以下责任组织实现；表中的名称不要求一一对应独立类或框架。

| 责任 | 输入 | 输出与所有权 |
| --- | --- | --- |
| `SessionController` | 用户配置、系统生命周期事件 | 会话 UUID、阶段和段配置；由 UI 主线程管理 |
| `DisplayInspector` | 当前显示器、显示模式、窗口与 drawable 尺寸 | 不可变显示配置快照；未知设置保留为空 |
| `PatternEncoder` | `UInt64 render_seq`、F68/C52、L/H | 固定顺序模块码值；不接触 UI、GPU 或时钟 |
| `MetalRenderer` | 冻结后的段配置、模块码值、显示回调 | 完整 drawable 和提交身份；在一个渲染执行上下文中操作 |
| `PresentationRecorder` | 提交结果、呈现回调、平台时间 | 不可变事件和待确认记录；按提交身份串行归并 |
| `SessionExporter` | 已封存日志、布局集合、段快照和导入标定 | 共享契约定义的目录；不改写原始事件 |
| `CalibrationPlayer` | 几何、灰度或互补翻转计划 | 带 `CALIBRATION` 标签的显示帧，不消耗动态序号 |

UI 状态变化不直接触发光学绘制。渲染回调只读取已冻结的段配置，不跨线程读取可变的当前 UI 状态。呈现回调捕获原提交的帧身份、段身份和布局身份，不能在回调执行时再查询当前段。

采用一个调度源。`CAMetalDisplayLink` 的 run loop 与图案绘制在同一个渲染上下文中；不要同时用 SwiftUI timer、`MTKView` 自动绘制或另一条 display link 推进序号。具体线程封装在建立工程时确定，本轮不引入线程框架。

## 3. 编码、布局和静态内容

### 3.1 编码器

编码器以 `UInt64` 保存动态序号，以截取低 16 位的方式取得 `payload_n`。CRC 的字节顺序、Gray/CRC 的屏幕位序和 Runner 索引严格采用共享契约，不按 Swift 的内存字节序编码。导出 `render_seq` 时转为规范十进制字符串，不能经由 `Double`。

暂停恢复、layer/目标重建或新段开始后，新的动态提交分配新的 `render_seq`，不能为恢复旧画面而沿用已提交序号。会话内连续递增的约束只表示不回零；屏幕自然保持旧状态与应用再次提交是两件事。

F68 和 C52 共用同一编码过程；C52 仅截取前 52 个模块。原设计提供的测试向量直接作为外部预期结果，后续验证不以同一段编码器再次计算出的数组作为唯一参照。`UInt64` 最大值可以作为输入验证；如果实际会话已到最大序号，下一次递增结束会话并报告原因，不在同一会话回绕到 0。

### 3.2 输出坐标

布局以 Metal drawable 实际像素尺寸计算。AppKit 的窗口 point 和视图缩放只用于取得最终 drawable 尺寸，不作为导出坐标。Metal 片元或顶点路径把输出坐标统一为左上角原点，避免将 AppKit 的视图坐标方向直接当作协议坐标。

默认 `pattern_rotation_deg=0`；`display_rotation_deg` 保存系统报告的旋转。实际模块矩形、标记轮廓顶点和旋转矩阵按共享契约导出。系统缩放与面板原生像素的映射没有确认前，不宣称一个 drawable 像素就是一个面板像素。

动态区以原设计的宽 96%、高 68% 为排布起点，再为四角标记和静区留出不重叠的区域。模块整数边界使用共享契约的取整公式。ArUco 单元同样使用整数边长，不能通过任意缩放一张低分辨率纹理生成模糊单元。

保留每段布局。Retina 缩放、全屏切换、显示模式变化或窗口移动到另一显示器后，旧布局对象不可覆盖。新段引用新的 `layout_id`；完全相同的布局可复用已有对象。

### 3.3 灰度与静态定位

使用固定 SDR 渲染配置。动态模块默认 L=32、H=224；ArUco 使用固定黑白与至少一单元白色静区。图案不使用抗锯齿、渐变或纹理线性插值。进入动态阶段后，不刷新非必要文字与调试动画。

渲染格式和色彩空间必须作为一组确定下来，保证 32/224 表示约定的 8 位码值。若使用 sRGB render target，不能把线性 shader 输出值简单设为 `32/255` 和 `224/255` 后就认为输出码值一致；需要考虑写入时的传递函数。后续以 drawable 格式、颜色空间配置和输出读回核对数字码值，物理发光亮度仍由标定测量。

只需要字典 `DICT_4X4_50` 的 ID 0–3，Mac 端可内置经 OpenCV 核对的精确位图，不为四个静态标记引入完整 OpenCV。布局 ID 顺序、黑边和顶点定义完全引用共享契约。

## 4. Metal 帧循环和呈现追踪

### 4.1 初始化

1. 选择目标内置显示器，读取系统显示模式和 drawable 尺寸，生成布局与段配置快照。
2. 创建 SDR `CAMetalLayer`、命令队列与绘图流水线，完成 shader 编译和绘制资源分配。
3. 创建会话 UUID、单调时钟原点、日志写入器和有界事件队列；先持久化配置和布局，再开始实验显示。
4. 创建绑定该 Metal layer 的 `CAMetalDisplayLink`，设置 delegate 并加入指定 run loop。
5. 进入全屏预览和预热；动态阶段开始前不消耗 `render_seq`。

分配多帧复用资源时必须确保 GPU 正在读取的 uniform 不被下一次回调覆盖。具体使用内联小型常量还是多缓冲，在首个静态图案实现时选择满足该约束的最小方案。本轮不预设额外资源池。

### 4.2 每次更新

1. 从 `CAMetalDisplayLink.Update` 取得本次 `drawable`、`targetPresentationTimestamp` 和 `targetTimestamp`。
2. 捕获当前冻结配置与阶段，分配会话内唯一的 `native_frame_id`。动态帧再分配 `render_seq` 并编码模块。
3. 使用实际像素布局绘制完整目标，完成命令编码。
4. 在提交前建立不可变追踪记录，注册 drawable 的 `addPresentedHandler`。
5. 在进入提交路径前紧邻采样 `submit` 时间，安排呈现并提交命令缓冲。若使用 `commandBuffer.present(drawable)`，先调用该方法，再 `commit()`；不能照搬“commit 后再调用 commandBuffer.present”的顺序。
6. 提交被接受后生成一次 `SUBMITTED`；若回调已先到，记录器先保存结果，再按共享契约顺序输出事件。

`targetTimestamp` 是本次 drawable 的呈现调用截止时间，`targetPresentationTimestamp` 是预计呈现时间。二者分别保存为 `deadline` 和 `target_present`；不能交换，也不能把任一值作为实际呈现证据。提交调度需要遵守 Apple 对所选呈现调用方式的时序要求。

`target_present` 始终取本次 `Update.targetPresentationTimestamp`，不因改用不同呈现调用方式而改为应用请求值。Android 对应字段固定取所选 FrameTimeline 的预计时间，其 EGL 请求另行保存；Mac 与 Android 共用字段语义，不要求两端拥有相同呈现 API。

### 4.3 呈现回调

回调读取 drawable 的 `presentedTime`，连同原始秒值交给记录器。有效非零结果转换为标准原始纳秒，追加 `PRESENTED`。零值按未确认处理，不用目标时间填补。`recorded` 保存回调处理时刻，与 drawable 报告的实际呈现时间分开。

记录器的待确认表以应用分配的 `native_frame_id` 索引。`platform_ids.drawable_id` 只保存公开 API 实际提供的原生标识；没有公开原生标识时写 `null`，实现时按目标 SDK 核实，不能根据本说明假定它必然存在或不存在。应用计数已由 `native_frame_id` 表达，不另增计数，也不将应用计数写成原生 ID。回调到达新段后，仍使用提交时保存的旧段与旧布局；段结束不删除尚可获得结果的旧追踪对象。

没有收到有效回调不等于帧已被证明丢弃。最终封存前仍缺回调的记录使用 `NO_CALLBACK_AT_SESSION_CLOSE`；收到明确无效时间的记录使用 `TIMESTAMP_INVALID`。退出目标或销毁目标时尚未确认的记录按共享契约使用 `SURFACE_DESTROYED`，原平台上下文说明它对应 Mac layer/目标销毁。

`UNCONFIRMED` 只表示截至记录时没有有效呈现证据。封存前仍获得真实有效结果时追加 `PRESENTED`，即使先前记录为 `INVALID` 或 `UNSUPPORTED`，也保留原生冲突诊断并接纳证据；不把所有原因统一当成终态，不增加额外状态机。封存后仍保持导出包不变。

## 5. Mac 时间字段映射

所有原始秒值保留在 `platform_timestamps` 中，条目键使用共享契约的标准时间前缀，条目内的 `api` 保存 API 名称；标准字段的整数换算和原点减法按共享契约执行。单调原点使用与 Metal host time 一致的时间源，不能使用 `Date` 的墙钟。实际工程需核对所选时间读取函数与 Metal host time 的域一致性。

| 标准前缀 | Mac 来源 | 状态与限制 |
| --- | --- | --- |
| `target_present` | `Update.targetPresentationTimestamp` | 有效值仍只是预计时间 |
| `deadline` | `Update.targetTimestamp` | 截止的是呈现调用；不是 GPU 已完成的证据 |
| `submit` | 进入本帧提交路径前的 host time 采样 | CPU 采样，不代表 GPU 开始或结束 |
| `system_present` | 呈现回调中的 `MTLDrawable.presentedTime` | 非零有效结果才标 `VALID` |
| `render_complete` | 本帧命令缓冲的 GPU 完成计时，待实现时核实 API 与时钟域 | 未取得可信结果时为空，不能用 CPU completion handler 的到达时刻冒充 |
| `latch` | v1.0 未指定可取得该语义的 Mac API | `UNSUPPORTED`，数值为空 |
| `recorded` | 事件生成时的 host time 采样 | 总是保留，与被记录事件的实际发生时刻分开 |

原设计要求输出 GPU 完成时间分布；只有取得并核实具有 GPU 完成语义的字段后才生成该统计。CPU 回调延迟可以另存平台诊断字段，不与 GPU 时间混用。

合成锁存具有对应的显示路径语义，缺少公开查询 API 只说明当前不能取得时刻，因此 `latch` 使用 `UNSUPPORTED`。`NOT_APPLICABLE` 留给事件或路径确实不具有相应语义的情形，不能用来表达“查不到”；本设计不据此声称已经观测到 Mac 的锁存时间。

## 6. 会话、分段与封存

主流程为设置、预热 10 s、会话卡 2 s、动态运行 90 s、结束卡 2 s、处理剩余呈现结果、封存和导出。卡片内容、灰度和非动态帧字段引用共享契约。采集控制器通过完整 UUID 将相机记录与本次导出包关联。

暂停、退出全屏、系统休眠、显示器更换、模式或 drawable 尺寸变化都会结束当前段。恢复后重新取得实际配置并建立新段。会话原点和动态序号继续使用；进程重启创建新会话。显示模式变化通知只能说明应用何时检测到变化，不能证明硬件切换恰好发生在通知时刻；配置事件保留检测时间，不据此伪造精确扫描切换边界。

这里“动态序号继续使用”指在已有序号之后分配新序号，不是重用旧提交。`M59-E20` 和 `M-CAL` 各开独立 `session_id`，不作为 `M59-S1` 或 `M120-S1` 会话中的普通分段；操作员切入这些实验时先封存当前会话，再创建新会话并选择对应 `experiment_profile`。Android 的 `A120-E12` 和 `A-CAL` 同理，不引入跨实验组标识。

应用主动改变布局或配置时，先停止旧段的新提交，再应用新配置。系统已经改变配置时，立即停止按旧配置生成新帧，保存通知和已有提交证据。后端结合实际事件排除无法确定配置的过渡区间。

结束时按共享契约最多额外等待 2 s 收集剩余结果，随后追加最终未确认记录并生成摘要。封存后的导出包不因迟到回调而改变。未确认记录随后获得有效结果的情况，只在封存前通过追加事件解决。查询失败使用 `QUERY_FAILED`；原生时间已取得但时钟域未核实使用 `CLOCK_DOMAIN_UNVERIFIED`。两者都保留原生来源与值，标准时间为空，不以 CPU 到达时刻替代。

## 7. 标定、日志与导出

没有 `display_profile` 时仍允许显示和导出，段绑定标记为 `MISSING`。导入文件后先保存原始模型与配置键；模型不完整或匹配项未知时使用 `IMPORTED_UNVERIFIED`，不能根据文件存在就标为 `COMPATIBLE`。亮度、色彩或显示模式变化后重新按新段配置核对，保留旧绑定。

Mac 端提供几何图案、灰度阶梯和保持亮暗面积的互补翻转图案，记录实际呈现。后端或外部标定程序拟合屏幕时序，应用不自行生成虚构的零扫描延迟模型。

事件队列有固定上限，写入器批量追加 JSONL。队列溢出处理直接遵循共享契约：独立锁存损失、停止新动态状态、结束受影响段、保留可写入事件、标记 `INCOMPLETE`。待呈现追踪容量耗尽则使用 `PENDING_QUEUE_FULL`，不能混写为日志溢出。磁盘错误导致导出不完整时报告导出失败。

`SessionExporter` 输出共享目录的 6 个文件。`layout.json` 保存所有被引用布局，`display_profile.json` 保存所有被引用标定及逐段绑定；不得只导出最后一段。首次实现可以导出目录，原设计允许目录或压缩包，因此不必先实现压缩。

## 8. 实现顺序和必要验证

以下是后续开发顺序，本轮不执行。

1. 建立最小原生 macOS 工程，实现独立编码器。用交付向量核对 F68/C52、CRC、位序和回绕；遍历 65536 个载荷检查原协议性质，验证完整 UInt64 的序列化。
2. 显示静态图案，核对实际 drawable 尺寸、整数边界、灰度码值和真实 ArUco 识别结果。静态显示成功前不加入动态会话操作。
3. 接入单一 Metal display link、逐帧身份和呈现回调。运行短动态会话，核对每个确认结果都关联正确提交，且无预计时间冒充实际时间。
4. 实现阶段切换、配置分段和共享导出。使用跨段迟到回调、尺寸变化、缺失标定和未确认结果验证数据契约。
5. 加入标定播放与原设计的 90 s/20 min 实验。识别率和时间精度由实际相机与独立延迟实验验证。

这些验证的预期来自公共协议、交付向量、API 语义和实际图像，不依据实现自身生成的结果。尚无工程、检查命令或实测数据，不能将本说明视为实现或验证完成报告。

## 9. 待协商事项和参考

共享契约 v1.0 已统一 JSON 类型、布局集合、坐标与旋转、ArUco、卡片和封存规则。manifest 与配置事件沿用契约第 2 节的准确键名、类型和枚举，Mac 不另建同义字段。屏幕数值模型 schema 需要识别算法端参与，本轮只确定缺失状态与不透明保留方式。Xcode 工程组织、签名与发布不影响本轮共享格式，留到应用开发任务确定。

- 原设计：`/Users/dengqi/Downloads/optical_sync_design/01_Mac显示应用设计.md`。
- [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink)：macOS 14 可用性、Metal layer 与 run loop 调度。
- [Update.targetTimestamp](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/update/targettimestamp)：drawable 呈现调用截止时间。
- [Update.targetPresentationTimestamp](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/update/targetpresentationtimestamp)：预计呈现时间。
- [MTLDrawable.presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)：实际呈现 host time 与零值语义。
- [MTLCommandBuffer.present(_:)](https://developer.apple.com/documentation/metal/mtlcommandbuffer/present(_:))：需要在 `commit()` 前调用该便利方法。
