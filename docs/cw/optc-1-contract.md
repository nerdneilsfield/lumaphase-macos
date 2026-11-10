# OPTC-1 显示端共享数据契约

状态：v1.0，Android 与 macOS 双方确认，尚未发布；2026-11-10 按协调者意见澄清恢复提交、时间来源、实验会话及迟到结果。

日期：2026-11-10。
范围：光学编码、布局、会话标识、显示日志和导出文件。本轮只制定文档，不实现应用。

原设计第三份报告第 2 节定义 `OPTC-1` 光学编码。本契约补充文件与事件语义，不改变编码。本文中的“必须”表示互操作所需的约束。`schema_version` 固定为 `"1.0"`，与光学协议名 `"OPTC-1"` 分开。双方仓库保存字节一致的本契约；平台实现说明分别维护。

## 1. 编码和数值类型

`render_seq` 是会话内单调递增的无符号 64 位状态身份。第一个动态状态使用 0；暂停、分段和 16 位回绕都不重置它。只有生成新的动态编码状态才消耗序号。预热、会话卡、结束卡和标定图案不消耗动态序号。

Surface 重建或暂停恢复后，每次新的动态提交都分配新的 `render_seq` 并重新编码；序号连续表示在同一会话内继续递增，不回到 0，不表示复用旧序号。旧图案在屏幕上自然保持不产生新提交；需要重新提交动态图案时，不能沿用旧 `render_seq` 形成多次提交。同一 `(session_id,render_seq)` 至多对应一次动态提交。

```text
n = render_seq mod 65536
g = n XOR (n >> 1)
CRC 输入字节：n & 0xff，然后 (n >> 8) & 0xff
CRC：width=8, poly=0x07, init=0, refin=false, refout=false, xorout=0
0 → [L,H]；1 → [H,L]；默认 L=32，H=224
```

模块按逻辑图案的 +x 方向排列；Gray 与 CRC 都是最高位先显示。F68 的 0–3 为 `[L,H,H,L]`，4–35 为 Gray，36–51 为 CRC，52–67 为 Runner。Runner 按索引 0 到 7 排列，只有 `n mod 8` 对应的位为 1。C52 保留模块 0–51。每个横截面沿逻辑 +y 方向重复。

文件中的类型统一如下。

| 字段类别 | JSON 表示 | 约束 |
| --- | --- | --- |
| `render_seq` | 十进制字符串 | 无符号 64 位，`"0"` 或不含前导零的数字串；禁止浮点解析 |
| `session_id` | 字符串 | 小写、带连字符的完整 UUID；短编号只用于显示 |
| `segment_id` | 字符串 | 会话内递增的十进制编号，从 `"0"` 开始，不复用 |
| `native_frame_id` | 字符串 | 应用分配，会话内唯一；不是直接使用 EGL frame ID |
| 平台原生帧 ID | 字符串或 `null` | 原值的十进制表示；作用域另行记录 |
| 所有标准 `*_ns` | JSON 整数或 `null` | 有符号 64 位纳秒；读取端使用 Int64、Long 或任意精度整数 |
| `event_seq` | JSON 整数 | 单个日志文件内从 0 递增；写入前分配，用于识别日志缺口 |
| `payload_n`、`crc8`、模块索引、像素坐标 | JSON 整数 | `payload_n` 为 0–65535，`crc8` 为 0–255 |

原生 API 的负值哨兵不进入标准时间字段。无效、待定和不支持均使用 `null`，原因由状态字段表达。JSON 的 `null`、数字 0 和缺少字段不是同义词。必填的可空字段必须显式写 `null`。本契约不要求使用 JavaScript；若读取器使用 JavaScript，必须使用能保留 64 位整数的 JSON 读取方式。

## 2. 会话目录和逐段快照

```text
session_<uuid>/
├── manifest.json
├── layout.json
├── display_events.jsonl
├── configuration_events.jsonl
├── display_profile.json
└── session_summary.json
```

JSON 使用 UTF-8。JSONL 每行是一个完整对象，以 LF 结束。导出后文件保持不变。未完成导出不能标为完整会话。

### 2.1 manifest 顶层字段

下列字段全部必填；可空字段取得不到值时写 `null`。本节“整数”遵循第 1 节的数值约定，“数值”允许有限 JSON 小数。

| 键 | 类型 | 含义 |
| --- | --- | --- |
| `schema_version` | 字符串 | 固定 `"1.0"` |
| `protocol_version` | 字符串 | 固定 `"OPTC-1"` |
| `session_id` | 字符串 | 会话 UUID |
| `platform` | 字符串 | `MACOS` 或 `ANDROID` |
| `source_device_id` | 字符串 | 显示设备在实验系统中的稳定标识 |
| `app_id` | 字符串 | bundle ID 或 Android application ID |
| `app_version` | 字符串 | 对外版本号 |
| `app_build` | 字符串 | 应用构建编号，保留平台原始字符串 |
| `os_version` | 字符串 | 系统版本号 |
| `os_build` | 字符串 | 系统构建标识；Mac build 或 Android build fingerprint |
| `clock_domain` | 字符串 | 第 6 节标准单调时钟域 |
| `time_origin` | 对象 | `raw_ns` 为整数，`native_clock` 为字符串，见第 6 节 |
| `presentation_drain_timeout_ns` | 整数 | 固定为 2000000000，结束卡后额外排空上限 |
| `segments` | 对象数组 | 按段创建顺序保存第 2.2 节快照 |

### 2.2 段快照字段

每个段对象使用以下准确键名；全部必填，只有类型明确允许时可为空。

| 键 | 类型 | 含义 |
| --- | --- | --- |
| `segment_id`、`layout_id` | 字符串 | 段身份与布局引用 |
| `display_mode_id` | 字符串或 `null` | 系统当前模式 ID，不是请求模式名 |
| `experiment_profile` | 字符串 | 如 `M59-S1`、`A120-S1` 或自定义实验名 |
| `drawable_width_px`、`drawable_height_px` | 正整数 | 实际输出尺寸 |
| `display_rotation_deg` | 整数或 `null` | 第 3 节的系统旋转角 |
| `requested_refresh_num`、`requested_refresh_den` | 正整数或 `null` | 本段请求/操作员选择的刷新率有理数；两者同时为空或非空 |
| `nominal_refresh_num`、`nominal_refresh_den` | 正整数或 `null` | 系统模式提供的精确标称有理数；两者同时为空或非空 |
| `reported_refresh_hz` | 正数值或 `null` | 系统模式报告的 Hz 值，保留有限小数，不伪造精确分数 |
| `brightness_setting` | 数值或 `null` | 可读取或人工确认的亮度设置，归一化到 0–1；不是实测亮度 |
| `brightness_source` | 字符串 | `SYSTEM_REPORTED`、`OPERATOR_REPORTED` 或 `UNKNOWN`；UNKNOWN 时设置值为空 |
| `auto_brightness_enabled` | 布尔或 `null` | 是否启用自动亮度；未知为空 |
| `color_space` | 字符串 | 渲染表面的实际色彩空间名称 |
| `pixel_format` | 字符串 | 渲染目标像素格式的原生名称 |
| `color_mode` | 字符串或 `null` | 当前显示色彩模式的原生名称 |
| `dimming_mode` | 字符串或 `null` | 当前调光模式的原生名称 |
| `hdr_enabled`、`true_tone_enabled`、`night_shift_enabled` | 布尔或 `null` | 当前功能状态；不适用或无法取得时为空 |
| `display_profile_id` | 字符串或 `null` | 本段导入标定引用；是否匹配另见第 9 节 |
| `operator_note` | 字符串 | 人工记录，默认空字符串 |

`pattern_rotation_deg`、`layout_profile` 和 L/H 从 `layout_id` 引用的布局取得，段对象不另存同义字段。标称刷新率无法精确取得时使用 `null`，不能用请求值冒充实测值。Mac 的 59.94 Hz 配置可用 `requested_refresh_num=60000`、`requested_refresh_den=1001` 记录选择；系统报告值和确认呈现间隔分别保存。平台特有的其他设置放在可选 `platform_configuration` 对象中，不替换上述键名。

每次模式、drawable 尺寸、布局、旋转、亮度或色彩配置变化都结束当前段；恢复显示时创建新段。旧段的布局和配置必须保留。不能把新 Surface 尺寸写回旧段。`layout.json` 是布局集合，`manifest.segments[].layout_id` 引用其中一个不可变对象；相同布局可以复用同一个对象。

`configuration_events.jsonl` 记录 `SEGMENT_STARTED`、`SEGMENT_ENDED`、`PHASE_CHANGED`、`RENDER_FAILURE`、`LOG_OVERFLOW`、`SESSION_CLOSED`。公共字段为 `event_seq`、`event_type`、`session_id`、`segment_id`（无活动段时为 `null`）、`recorded_raw_ns`、`recorded_ns`、`details`。每个分段开始事件保存该段的完整配置快照，结束事件包含原因。最终 manifest 汇总这些段；不依靠最终显示配置反推历史配置。

### 2.3 配置事件 details

下表列出每种事件必填的最小 `details` 键；字符串原因的自定义说明使用可选 `message` 字符串，不能改变标准枚举含义。

| `event_type` | `details` 必填键与类型 |
| --- | --- |
| `SEGMENT_STARTED` | `configuration`：第 2.2 节的完整段对象；`reason`：`SESSION_START` 或 `RESUME` 或 `CONFIGURATION_CHANGED` |
| `SEGMENT_ENDED` | `reason`：`NORMAL_END`、`PAUSED`、`BACKGROUND`、`FULLSCREEN_EXIT`、`SYSTEM_SLEEP`、`DISPLAY_CHANGED`、`SURFACE_CHANGED`、`CONFIGURATION_CHANGED`、`LOG_OVERFLOW`、`RENDER_FAILURE`、`USER_STOP` 之一 |
| `PHASE_CHANGED` | `previous_phase`：字符串或 `null`；`phase`：第 5 节阶段字符串；`planned_duration_ns`：非负整数或 `null`，无计划时为空 |
| `RENDER_FAILURE` | `native_frame_id`：字符串或 `null`，分配前失败时为空；`render_seq`：十进制字符串或 `null`；`operation`：字符串，失败 API/操作名；`error_code`：字符串或 `null`，保留原生错误码；`message`：字符串 |
| `LOG_OVERFLOW` | `affected_log`：`display_events.jsonl` 或 `configuration_events.jsonl`；`affected_segment_ids`：字符串数组；`first_lost_event_seq`、`last_lost_event_seq`：非负整数；`lost_event_count`：正整数，见第 10 节 |
| `SESSION_CLOSED` | `reason`：`NORMAL_END`、`USER_STOP`、`LOG_OVERFLOW` 或 `RENDER_FAILURE`；`data_integrity`：`COMPLETE` 或 `INCOMPLETE`；`pending_frame_count`：非负整数，封存时未获有效呈现结果的已提交帧数 |

`PHASE_CHANGED` 的 `phase` 还允许 `IDLE`、`CONFIGURED`、`PAUSED`、`EXPORT`，它们不生成显示帧；显示事件中的 `phase` 仅取第 5 节的显示阶段。`SEGMENT_STARTED.configuration.segment_id` 与公共 `segment_id` 必须一致。`SESSION_CLOSED.pending_frame_count` 包含最终未确认帧，不表示封存后还会继续查询。

## 3. 布局坐标、旋转与模块边界

### 3.1 唯一取样坐标系

`layout.json` 内所有已导出的几何坐标都使用实际 drawable/Surface 输出坐标：左上角为 `(0,0)`，x 向右，y 向下，单位为输出像素。它不是 SwiftUI point、Android dp、相机像素或 OpenGL 的左下角坐标。像素中心为 `(x+0.5,y+0.5)`；矩形边界采用半开区间 `[x0,x1) × [y0,y1)`。

输出像素不自动等于面板原生像素。若系统缩放或合成导致二者不同，应用记录 drawable 尺寸与显示模式；屏幕时序标定绑定本布局输出坐标。需要面板原生坐标的标定程序负责建立显式映射，不能把未知映射默认为恒等映射。

每个布局对象包含以下字段。

| 字段 | 含义 |
| --- | --- |
| `layout_id` | 布局对象的不可变身份；会话内唯一 |
| `layout_profile` | `F68` 或 `C52` |
| `drawable_width_px`、`drawable_height_px` | 实际绘制目标尺寸，正整数 |
| `coordinate_system` | 固定为 `DRAWABLE_TOP_LEFT_PIXEL_EDGES` |
| `pattern_rotation_deg` | 逻辑图案到输出坐标的顺时针旋转：0、90、180 或 270 |
| `pattern_width_px`、`pattern_height_px` | 旋转前的逻辑画布尺寸 |
| `pattern_to_drawable` | 第 3.2 节定义的 3×3 齐次矩阵，按行保存 |
| `dynamic_rect_px` | 旋转后的动态区包围矩形 `[x0,y0,x1,y1]` |
| `modules` | 按协议模块索引排列的对象，含 `index`、旋转后的 `rect_px` |
| `markers` | 第 4 节的定位标记对象 |
| `level_low`、`level_high` | 8 位 SDR 码值，默认 32、224 |

`layout.json` 的外层为 `{"schema_version":"1.0","layouts":[...]}`。布局对象中的坐标已经完成旋转。读取端直接按 `rect_px` 取样，不再次应用旋转；矩阵用于解释方向和核对坐标。

### 3.2 图案旋转和系统旋转分开

设旋转前画布为 `Wp × Hp`，边界坐标为 `(x,y)`。图案旋转的边界变换如下。

| `pattern_rotation_deg` | `(xd,yd)` | 输出尺寸 |
| --- | --- | --- |
| 0 | `(x,y)` | `Wp × Hp` |
| 90 | `(Hp-y,x)` | `Hp × Wp` |
| 180 | `(Wp-x,Hp-y)` | `Wp × Hp` |
| 270 | `(y,Wp-x)` | `Hp × Wp` |

例如，90° 的矩阵为 `[[0,-1,Hp],[1,0,0],[0,0,1]]`。矩形转换四个边界角后取最小、最大坐标。旋转不改变模块索引或 Gray/CRC 位序。

`display_rotation_deg` 表示系统报告的相对自然方向的绘制补偿旋转标签，取 0、90、180、270；无法取得时为 `null`。Android 的 `Display.getRotation()` 返回值 `ROTATION_0/90/180/270` 直接映射为 0/90/180/270，它描述绘制补偿，与设备物理转动方向相反；该字段不表示设备物理转动的顺时针角度。平台原始旋转枚举保存于平台字段。该字段只描述设备显示配置，不再作用于已经导出的布局坐标。屏幕扫描方向由实测标定给出，不能从 `display_rotation_deg` 或手机竖屏状态推断。

### 3.3 非整除宽度

旋转前动态区 x 范围为 `[a,b)`，模块数为 M。第 i 条边界使用 `a + floor(i × (b-a)/M)`，i 为 0 到 M。每个模块因此具有整数边界，宽度最多相差 1 像素；动态区宽度小于 M 时不启动该布局。两端与后端均以实际导出的模块矩形为准，不以百分比重新计算。

原设计的宽 96%、高 68% 是布局建议，不是后端的固定几何假设。静态标记和留白不得与动态区重叠。模块边缘不使用抗锯齿或线性插值。

## 4. ArUco 定位标记

两端固定使用 OpenCV 预定义字典 `DICT_4X4_50`，`marker_size_bits=4`，`border_bits=1`。在未旋转的逻辑画布中，ID 0、1、2、3 分别位于左上、右上、右下、左下。图案旋转时，标记随整个光学目标一起旋转，ID 不按旋转后的屏幕角落重新分配。

每个标记对象包含 `id`、`dictionary`、`marker_size_bits`、`border_bits`、`cell_size_px`、`quiet_zone_px`、`corners_px`。每个单元使用相同的整数像素边长；外侧黑边为 1 个单元，白色静区至少为 1 个单元。白色静区与标记黑边不属于动态模块。

`corners_px` 为标记黑边外轮廓的四个边界顶点；顺序按标记自身未旋转坐标的左上、右上、右下、左下，随后随图案变换到输出坐标。它不是按最终图像位置重新排序后的顶点，也不是白色静区的边界。后端用 ID 和标记自身方向匹配顶点。标记使用固定黑白，灰度码值为 0、255；动态条码仍使用 L、H。

字典位图必须来自该预定义字典的实际数据。显示端可内置 ID 0–3 的精确位图，不要求运行时依赖完整 OpenCV；不能用外观类似的自绘方块替代。内置位图与 OpenCV 字典一致性属于尚待执行的验证。

## 5. 会话卡与动态状态

默认阶段为 `WARMUP` 10 s、`SESSION_CARD` 2 s、`RUNNING` 90 s、`END_CARD` 2 s。漂移实验的 `RUNNING` 为 1200 s。阶段切换分别写 `PHASE_CHANGED`，并保留对应显示帧的提交与呈现事件。阶段的计划时长不是精确发光时长；后端使用确认呈现事件确定边界。

Android 的 `A120-E12` 长曝光实验和 `A-CAL` 标定各自创建独立 `session_id`，不作为 `A120-S1` 会话中的普通分段；Mac 的 `M59-E20` 长曝光实验和 `M-CAL` 标定同理，各自创建独立会话，不作为 `M59-S1` 或 `M120-S1` 会话中的普通分段。各会话分别导出完整目录并记录其 `experiment_profile`；本版不增加 `experiment_group_id`。

会话卡和结束卡保留四角定位标记，动态区改为统一中灰 128，不放置合法 F68/C52 动态载荷。卡片显示 `OPTC-1`、完整 `session_id`、平台名，以及 `START` 或 `END`；短编号可额外显示。用户或采集控制器用完整 UUID 关联实验数据，不要求后端通过 OCR 恢复它。v1.0 不增加 QR 或另一套光学会话协议。

事件中的 `frame_kind` 取 `WARMUP`、`SESSION_CARD`、`DYNAMIC`、`END_CARD`、`CALIBRATION`。仅 `DYNAMIC` 帧有非空 `render_seq`、`payload_n`、`crc8`；其余三字段为 `null`。静态预览若显示合法条码，也归入 `CALIBRATION`，不混入动态序列。`phase` 取同名会话阶段；标定使用 `CALIBRATION`。

一个动态状态可以自然保持多个刷新周期，但只有一次提交身份。在没有新提交的保持期间，不人为制造新的 `render_seq` 或 `PRESENTED` 事件；恢复或重建后需要新提交时，按第 1 节分配新序号。后端以相邻已确认状态确定保持区间，并保留未确认状态带来的歧义。

## 6. 原始时间、相对纳秒与字段状态

### 6.1 时钟域和转换

一个会话只使用一个标准单调时钟域。Mac 使用 `MACOS_HOST_TIME`，Android 使用 `ANDROID_MONOTONIC`。`time_origin` 为 `{"raw_ns":整数,"native_clock":字符串}`，在任何预热提交前采样，会话内不变。系统休眠或模式切换不重新置零；时钟域失效或进程重启后创建新会话。

所有标准时间戳同时保留 `xxx_raw_ns` 和 `xxx_ns`，严格满足：

```text
xxx_ns = xxx_raw_ns - manifest.time_origin.raw_ns
```

`*_raw_ns` 是本机单调时钟读数，不是 Unix 时间；`*_ns` 是相对会话原点的整数纳秒。持续时间如 `exposure_ns`、`presentation_drain_timeout_ns` 不减原点。不同设备的原始时间不能直接相减。

Mac 的秒制原始浮点读数另外保存在 `platform_timestamps`，不能只留下换算结果。标准原始纳秒采用秒值乘 1e9 后四舍五入到最近整数，正中间取远离零方向，再减整数原点取得相对值。转换增加的十进制位不代表 API 或屏幕具有纳秒测量精度。Android 原生整数纳秒不经过浮点转换。

异时钟域字段必须在平台数据中保留来源；只有证实与标准域一致，或具有显式时钟转换及其元数据时，才填入标准 `*_raw_ns`。不能默认把任意 EGL 时间戳、墙钟或接收时间放进标准呈现字段。原生值虽有效但时钟域尚未证实时，该字段使用 `CLOCK_DOMAIN_UNVERIFIED` 状态，标准原始与相对纳秒均为空，原生值保留在 `platform_timestamps`。

### 6.2 每个字段独立表达有效性

各事件包含 `timestamp_status` 对象。其键为 `target_present`、`system_present`、`submit`、`deadline`、`render_complete`、`latch`；每个值为 `VALID`、`PENDING`、`INVALID`、`UNSUPPORTED`、`NOT_APPLICABLE`、`QUERY_FAILED` 或 `CLOCK_DOMAIN_UNVERIFIED`。`VALID` 表示该字段的原始与相对纳秒均非空；其他状态下二者均为 `null`。目标预计时间即使 `VALID`，也仍然只是预计时间。

`QUERY_FAILED` 表示本次平台查询调用失败，没有得到可信字段结果；它不同于调用成功后返回的 `INVALID`。`CLOCK_DOMAIN_UNVERIFIED` 表示已获得原生值，但无法确认它与本会话标准域的关系；它不同于原生值本身无效。两种状态都可以在后续查询或域核实后变为 `VALID`，封存前按追加事件保留取得的最终结果。

`platform_timestamps` 的标准条目以标准时间前缀为键，每个条目至少包含 `api`（字符串）、`native_value`（原始整数的十进制字符串、原始浮点数或 `null`）、`native_unit`（`NS`、`SECONDS` 或 `null`）、`native_clock_domain`（字符串或 `null`）、`query_error_code`（字符串或 `null`）。Mac 原始秒值在相应条目保存；Android 原始整数、哨兵均以字符串保存，避免原生 64 位值丢失精度。条目可增加原始状态和转换元数据，但不能用这些扩展改变标准字段含义。Android 额外使用 `egl_presentation_request` 条目保存第 6.3 节的 EGL 请求，采用相同条目结构。

`render_complete=VALID` 不蕴含 `system_present=VALID`。Android 必须分别判断 EGL 每一种时间戳的扩展支持和查询状态，不能用一个整体的 `VALID` 覆盖所有字段。平台原生 `PENDING`、`INVALID` 等哨兵及查询错误另外保存在 `platform_timestamps`。Mac 的 `presentedTime=0` 不转换成有效呈现时间。

标准时间字段前缀如下。

| 前缀 | 语义 |
| --- | --- |
| `target_present` | 系统预计的本帧呈现时间 |
| `system_present` | 系统返回的本帧实际呈现/扫描输出时间；不是像素发光时间 |
| `submit` | 应用调用提交/交换入口前紧邻采样的时间，不是 GPU 完成时间 |
| `deadline` | 平台给出的提交或呈现调用截止时间；平台说明须写清具体 API 语义 |
| `render_complete` | 平台返回的本帧渲染完成时间 |
| `latch` | 合成器锁存时间；不支持时为空 |
| `recorded` | 应用采样并生成该条事件的时间，独立于呈现时间 |

`recorded_raw_ns`、`recorded_ns` 总是有效，不放入状态对象。其余六组标准时间字段在每条显示事件中均存在；平台不适用的字段使用 `NOT_APPLICABLE`。

`UNSUPPORTED` 表示该事件在当前显示路径中有对应物理或调度语义，但当前平台、API 或查询能力不提供该字段；`NOT_APPLICABLE` 只用于该事件或显示路径确实没有对应语义的情况。缺少公开查询 API 本身不构成“不适用”。Mac 的合成锁存 `latch` 保持 `UNSUPPORTED`、标准值为空，不能仅因没有公开查询接口改标 `NOT_APPLICABLE`；这也不表示已测得锁存事件或其时刻。

### 6.3 target_present 与 deadline 的固定来源

Android 的 `target_present` 固定来自本次所选 `FrameTimeline.getExpectedPresentationTimeNanos()`，`deadline` 固定来自同一 timeline 的 `getDeadlineNanos()`。Mac 的 `target_present` 固定来自 `Update.targetPresentationTimestamp`，`deadline` 来自 `Update.targetTimestamp`。字段来源不能随着 EGL 扩展支持情况、查询结果或呈现方式切换。

Android 在支持 `eglPresentationTimeANDROID` 并调用它时，当前实现将同一个 FrameTimeline 预计呈现值作为请求参数。该请求值独立保存在 `platform_timestamps.egl_presentation_request`，`api="eglPresentationTimeANDROID"`；未调用时该条目的 `native_value=null`。请求值不会成为标准 `target_present` 的另一种来源，也不证明实际呈现。即使某个平台预计时间与其传入 EGL 的请求值相同，二者仍按来源分别记录。

## 7. 提交、迟到呈现和平台帧号

### 7.1 共同事件字段

`display_events.jsonl` 每行包含：`event_seq`、`event_type`、`session_id`、`segment_id`、`layout_id`、`native_frame_id`、`frame_kind`、`phase`、`render_seq`、`payload_n`、`crc8`、第 6 节的时间字段与 `timestamp_status`、`present_kind`、`unconfirmed_reason`、`platform_ids`、`platform_timestamps`。

`event_type` 使用原设计的 `SUBMITTED`、`PRESENTED`、`UNCONFIRMED`。同一提交的关联主键为 `(session_id,native_frame_id)`。`DYNAMIC` 帧另用 `(session_id,render_seq)` 关联编码；二者在一次会话内一一对应。`segment_id`、`layout_id`、编码载荷和帧身份在提交时捕获，此后不可从“当前段”重新读取。

`platform_ids` 的公共形状为 `{"surface_instance_id":字符串或null,"egl_frame_id":字符串或null,"vsync_id":字符串或null,"drawable_id":字符串或null}`。Android 每次创建 Surface 分配新的 `surface_instance_id`。EGL 查询和关联至少使用 `(session_id,segment_id,surface_instance_id,egl_frame_id)`；即使 frame ID 在新 Surface 中重复，也不关联到旧提交。Mac 不适用的字段为空，`drawable_id` 只保存平台公开 API 可取得的原生标识，没有这样的标识时为 `null`。应用分配的帧计数已由 `native_frame_id` 表达，不能写入 `drawable_id` 冒充原生标识，也不为此新增另一计数。

### 7.2 事件行为

1. 调用提交或交换入口前，应用建立不可变帧记录、捕获身份并注册追踪。平台接受提交后，记录器追加一次 `SUBMITTED`。该事件说明提交被接受，不证明帧已显示。提交失败写 `RENDER_FAILURE` 配置事件，保留已消耗的动态序号，不能伪造 `SUBMITTED`。
2. 收到有效实际呈现时间后，记录器追加一次 `PRESENTED`，`system_present` 状态为 `VALID`，`present_kind=SYSTEM_REPORTED`。Mac 使用呈现回调，Android 使用异步 EGL 查询。渲染完成、锁存或预计时间不能单独生成 `PRESENTED`。
3. 无法确认时追加 `UNCONFIRMED`，`system_present` 非 `VALID`，`present_kind=UNCONFIRMED`，并填写原因。它表达“截至此条记录未确认”，不等于证明该帧未上屏。
4. 封存前后续仍取得真实有效结果时，可以在 `UNCONFIRMED` 后追加 `PRESENTED`。后端按主键合并，确认结果覆盖先前的未确认状态；旧行保留。未确认原因不是一组统一的终态，不据此增加状态机。尤其是先前记录 `INVALID` 或 `UNSUPPORTED` 后又取得矛盾的有效值时，保留原生状态、来源、错误与结果诊断，不静默抹去前一记录，也不因先前原因拒收真实证据。重复通知不重复追加同一有效结果；相互矛盾的有效结果保留诊断，不能静默覆盖。

记录器保证同一主键的 `SUBMITTED` 在其结果事件之前入日志。回调可能早于提交路径结束，记录器此时暂存结果，直到提交结果确定。该要求不允许渲染线程等待文件写入。日志溢出破坏此保证时按第 10 节显式记录缺失。

日志文件顺序是事件记录顺序，不是屏幕呈现顺序。迟到事件继续使用原提交的 `segment_id`、`layout_id` 和 Surface 身份，即使新段已经开始。后端先合并提交，再按段、有效 `system_present_raw_ns` 和状态身份建立时序；不按 JSONL 行号或回调到达顺序推断呈现顺序。相同或倒退的有效呈现时间保留原值并报告异常，不修改时间使其递增。

### 7.3 未确认原因和会话封存

`unconfirmed_reason` 在非 `UNCONFIRMED` 事件中为 `null`，否则使用以下值。

| 原因 | 触发条件 |
| --- | --- |
| `TIMESTAMP_UNSUPPORTED` | 实际呈现时间戳类型不受支持 |
| `TIMESTAMP_INVALID` | 平台明确返回该字段无效；原生值保留 |
| `QUERY_FAILED` | 实际呈现时间查询调用失败，没有可信查询结果 |
| `CLOCK_DOMAIN_UNVERIFIED` | 已取得实际呈现原生值，但其时钟域与会话标准域的关系尚未确认；标准值为空 |
| `HISTORY_EXPIRED` | 平台明确表明旧帧的查询历史已失效 |
| `PENDING_QUEUE_FULL` | 有界待查询/追踪队列已满，无法继续跟踪该提交 |
| `SURFACE_DESTROYED` | Surface 或目标被销毁，尚无有效实际呈现结果 |
| `PENDING_AT_SESSION_CLOSE` | 导出封存时查询仍 pending |
| `NO_CALLBACK_AT_SESSION_CLOSE` | 封存时没有收到呈现回调 |

平台无法区分历史过期与一般无效时使用 `TIMESTAMP_INVALID`，不能仅凭帧龄宣称 `HISTORY_EXPIRED`。待查询队列满与日志队列满是两种故障，后者按第 10 节处理。

正常分段不丢弃旧段的待确认记录。Surface 仍有效时可以继续查询；销毁前先处理已有结果，其余记录上述原因。结束卡结束后最多再等待 2 s 处理待确认结果，`presentation_drain_timeout_ns=2000000000` 写入 manifest。随后对剩余记录追加未确认事件并生成 `SESSION_CLOSED`，其 `recorded_raw_ns` 为封存界限。封存之后到达的回调不再修改这份导出包。封存前已获得的有效结果优先于任何未确认原因。

`QUERY_FAILED` 原因对应 `timestamp_status.system_present=QUERY_FAILED`；`CLOCK_DOMAIN_UNVERIFIED` 原因对应同名字段状态。封存时若已有这两类明确障碍，最终记录保留该具体原因，不统一改成 pending；仅仍为 `PENDING` 的查询使用 `PENDING_AT_SESSION_CLOSE`。应用在 `platform_timestamps.system_present` 中保留原生值、来源和查询错误。单次查询失败不要求立即放弃后续查询。

`EXPECTED_ONLY` 与 `REFERENCE_FITTED` 只用于后端推导产物，显示应用不把它们写成实际呈现证据。

## 8. 事件关联示例

下列是完整事件中与关联有关的字段投影，不是可以独立提交给读取器的完整记录。时间为演示值，原点为 1000000000 ns。

```json
[
  {"event_seq":0,"event_type":"SUBMITTED","session_id":"6bd9ff04-8b4c-4df4-a5d9-86baa7c86d30","segment_id":"0","layout_id":"layout-0","native_frame_id":"42","render_seq":"65536","payload_n":0,"system_present_raw_ns":null,"system_present_ns":null},
  {"event_seq":1,"event_type":"UNCONFIRMED","session_id":"6bd9ff04-8b4c-4df4-a5d9-86baa7c86d30","segment_id":"0","layout_id":"layout-0","native_frame_id":"42","render_seq":"65536","unconfirmed_reason":"PENDING_QUEUE_FULL","system_present_raw_ns":null,"system_present_ns":null},
  {"event_seq":2,"event_type":"SUBMITTED","session_id":"6bd9ff04-8b4c-4df4-a5d9-86baa7c86d30","segment_id":"1","layout_id":"layout-1","native_frame_id":"43","render_seq":"65537","payload_n":1,"system_present_raw_ns":null,"system_present_ns":null},
  {"event_seq":3,"event_type":"PRESENTED","session_id":"6bd9ff04-8b4c-4df4-a5d9-86baa7c86d30","segment_id":"0","layout_id":"layout-0","native_frame_id":"42","render_seq":"65536","system_present_raw_ns":1120000000,"system_present_ns":120000000}
]
```

最后一行仍属于段 0。帧 42 最终有系统呈现证据，不能因其结果晚于段 1 的提交而归入段 1，也不能继续只按先前未确认状态处理。若因队列满而彻底放弃了查询，通常不会再得到结果；此例只说明在回调或已经发出的查询后来仍返回有效结果时的合并规则。

## 9. 缺失标定和配置匹配

没有实测屏幕标定仍可显示、记录和导出。`display_profile_id=null`；不得生成零延迟、瞬时响应或假定匀速扫描的标定冒充实测值。状态识别和系统时间线检查可以进行，依赖标定的精细光学时间估计不可据此宣称成立。

`display_profile.json` 即使没有标定也存在，外层包含 `schema_version`、`profiles`、`segment_bindings`。缺失时 `profiles=[]`；每个 binding 包含 `segment_id`、`profile_id`（可空）、`status`、`mismatch_fields`。状态为 `MISSING`、`IMPORTED_UNVERIFIED`、`COMPATIBLE` 或 `INCOMPATIBLE`。文件存在不等于配置匹配，也不等于精度通过验收。

每个导入 profile 包含 `profile_id`、`calibration_key` 和原始 `model` 对象。`calibration_key` 至少包括显示设备、系统构建、显示模式、drawable 尺寸、显示旋转、图案旋转、亮度、色彩与调光配置，以及标定版本。无法读取的配置项为 `null` 并记录人工备注；依赖这些未知项的匹配不能标为 `COMPATIBLE`。具体配置取值允许平台扩展，但相同字段名不能跨平台改变含义。

应用只导入和保留标定，不负责从显示日志生成实测 `tau(x,y)`、亮暗响应或调制模型。后端屏幕模型的数值 schema 仍需识别算法端定稿；v1.0 将 `model` 视为不透明对象，不能声称已具备跨后端互换能力。标定键沿用第 2 节准确键名及布局的 `pattern_rotation_deg`；标定版本键为 `calibration_version`（字符串）。一个段绑定的标定不随新段替换，所有被引用的 profile 保留在导出包中。

## 10. 日志溢出和数据完整性

渲染路径使用有界事件队列，文件写入由后台完成。队列满后不能覆盖旧事件，也不能阻塞渲染线程等待磁盘。

首次溢出时，记录器在独立于事件队列的锁存状态中保存丢失计数、首末丢失 `event_seq` 和受影响段，停止生成新的动态状态，并结束受影响段。后台写入器排空队列后写 `LOG_OVERFLOW` 配置事件。锁存记录不依赖往已满队列继续塞一条事件。首末编号只是损失范围边界，不声称范围内所有事件都丢失。

`LOG_OVERFLOW.details` 包含 `affected_log`、`affected_segment_ids`、`first_lost_event_seq`、`last_lost_event_seq`、`lost_event_count`。后续在停止过程中仍发生的损失继续累计到 `session_summary.json`；单条通知不承担最终计数。所有已写入事件原样保留，受影响段标为 `INCOMPLETE`。应用不能把被日志丢失影响的会话标为完整，也不能把“缺少 PRESENTED 行”自动解释成帧未显示。

`session_summary.json` 包含 `session_id`、`closed_raw_ns`、`closed_ns`、`data_integrity`（`COMPLETE` 或 `INCOMPLETE`）、`lost_event_count`、`segments` 和统计。各段统计包含生成、提交、最终确认呈现、最终未确认数量，以及 `data_integrity`、未确认原因计数。数量按提交主键归并后统计，不能把 `UNCONFIRMED` 后又确认的帧计入最终未确认数量。待查询队列满但日志完整时，数据完整性仍可为 `COMPLETE`；呈现证据覆盖率会下降。

文件写入失败与日志队列溢出分开报告。若磁盘错误使事件或摘要无法写入，导出操作返回失败，不能提供一份声称完整的成功导出包。

## 11. 双端互操作检查

本节是协议检查范围，不表示已经执行。

1. 使用原设计 `validation/protocol_test_vectors.json`，比较 F68 模块数组、CRC 与 Runner；并覆盖 `render_seq="65536"` 和无符号 64 位上界的解析与编码。
2. 检查 0、90、180、270° 下模块与 ArUco 顶点坐标，确保 Android 和 Mac 导出的最终坐标不被后端再次旋转。
3. 读入含不同 drawable 尺寸的两段会话，确认旧布局和旧 Surface 帧号关联未被覆盖。
4. 读入 `SUBMITTED → UNCONFIRMED → PRESENTED` 及跨段迟到结果，核对主键与最终计数。
5. 分别检查渲染完成有效而呈现 pending、不支持实际呈现、查询失败、时钟域未确认、Surface 销毁、历史失效、封存时 pending 的记录。
6. 检查缺失标定与日志溢出导出包，确认不生成虚假的标定或完整性结论。

## 12. 版本与确认记录

2026-11-10，Android 主 agent 明确接受左上原点与半开矩形、独立两类旋转、布局集合逐段引用、ArUco 字典与 ID、完整 UUID 和中灰会话卡、序号字符串、逐字段状态、EGL 复合主键、2 s 排空上限及缺失标定集合。按其反馈补充 `QUERY_FAILED`、`CLOCK_DOMAIN_UNVERIFIED`、准确 manifest 键名与配置事件 details 后，本版标为双方确认的 v1.0。

同日，经协调者判断的审阅修订明确：恢复/重建后的动态提交使用新序号；标准预计时间与截止时间采用固定系统来源；`A120-E12` 与 `A-CAL` 分别使用独立会话；未确认结果在封存前可由真实呈现证据补充，并保留冲突诊断。本版尚未发布，这些澄清继续使用 `schema_version="1.0"`，由协调者同步各仓库副本。

本次确认限于显示端数据与交接语义。屏幕模型 `model` 的数值 schema 留给识别后端；v1.0 只统一其容器、引用和缺失语义。后续影响公共键名、类型或语义的变更须同步两端契约，不能仅修改一端的平台说明。

## 来源

- 原设计：`/Users/dengqi/Downloads/optical_sync_design/01_Mac显示应用设计.md`。
- 原设计：`/Users/dengqi/Downloads/optical_sync_design/02_Android显示应用设计.md`。
- 编码权威：`/Users/dengqi/Downloads/optical_sync_design/03_识别算法与多双目对时设计.md` 第 2 节。
- [MTLDrawable.presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)：原生秒制 host time 与未呈现/丢帧时的零值。
- [EGL_ANDROID_get_frame_timestamps](https://registry.khronos.org/EGL/extensions/ANDROID/EGL_ANDROID_get_frame_timestamps.txt)：Android 侧需据此核实各字段时钟域、状态和查询生命周期。
