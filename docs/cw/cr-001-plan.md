# CR-001 v1.1：macOS 实施范围与共享格式决定

日期：2026-11-10。状态：协调决定已写入本仓库共享契约，等待协调者核对并字节同步；本轮未修改产品代码。

需求依据为完整的 `/Users/dengqi/Downloads/LumaPhase_远距低分辨率布局_最小改动说明.md`。格式决定来自 Android 主协调者的 `docs/cw/cr-001-plan.md`；准确键名、类型、读取规则以 [OPTC-1 共享契约](optc-1-contract.md) 为准，本文不另立一套接口。

## 当前代码与验证证据

当前 HEAD 为 `3a97a76b8b1fbdc828cc0943e411a25086b991c7`（`feat: release initial Apple Silicon macOS display app`），也是 v0.1.0 标签对应提交。应用已有 OpticCore、OpticDisplay、原生 LumaphaseApp，部署 macOS 14、只交付 Apple Silicon；包含 F68/C52 条带、四旋转、四种 Mac 实验配置、标定播放、Metal 提交/呈现记录、分段与六文件导出。网格尚未实现。

上一轮运行 `swift test --arch arm64 --jobs 3`，55 项 core 和 11 项 display 测试全部通过，包括离屏 Metal 像素回读。日志位于 `/tmp/lumaphase-cr001-recon/tests.log`。当时未打开应用窗口或切换显示模式；本轮仅验证文档和共同 fixture，没有重跑无变化的产品测试。当前 Swift 5 语言模式下 CAMetalDisplayLinkDelegate 的 Swift 6 actor 隔离警告仍存在，不在本次格式任务中修改。

[原实施记录](implementation-plan.md) 中的真实短会话及呈现探针不能证明所有实体实验已经完成：现有模式证据为 60 Hz，不能宣称已实测 59.94/120 Hz。长时运行、远距离成像、亮暗响应与光学精度仍需设备数据。原契约随 v0.1.0 发布的事实已写回历史记录，继续支持 schema 1.0。

## 保留功能与新增几何

| 选择名称 | 载荷族 | 行 × 列 | 数据格 / 填充格 | 第一批行为 |
| --- | --- | --- | --- | --- |
| F68-G6x12 | F68 | 6 × 12 | 68 / 4 | Mac 新默认 |
| C52-G5x12 | C52 | 5 × 12 | 52 / 8 | Mac 可选 |
| F68 | F68 | 1 × 68 | 68 / 0 | 保留原单排 |
| C52 | C52 | 1 × 52 | 52 / 0 | 保留原单排 |

Android F68-G9x8、C52-G9x6 纳入共同契约和预期，不在 Mac 实现 Android 渲染。F68-G4x18 为后续可选实验，不要求第一批支持。

CR 1.5 的扩大面积与 2.5 保持旧边界存在张力，协调者确定首批按 2.5：Mac 原动态区宽 96%、高 68%，原整数居中公式、标记边界、DICT_4X4_50 和 ID 0–3 保持。后续现场调整面积另行处理。两平台旧动态区不必相同。

编码器、Gray、CRC、Runner、render_seq、日志事件语义和刷新策略不变。M59-S1、M120-S1、M59-E20、M-CAL 继续完成；M59-E20 与 M-CAL 分别使用独立 session_id。新布局不替代原功能和原实验。

## 已统一的共享格式

新会话已有版本字段统一写 schema_version=1.1；光学协议保持 OPTC-1，原六文件及事件字段保持。geometry_profile 是唯一几何判别，不增加 grid_profile/layout_kind。layout_profile 仍只表示 F68/C52，layout_id 仍是会话内不可变对象身份。

所有新布局，包括单排，完整写 grid_rows、grid_cols、module_count、padding_count、module_order、sampling_inner_fraction 和 padding。modules 仍仅有 68/52 项原 index 与最终 drawable rect_px。padding 独立保存 slot_index、role=padding、rect_px、level；level 使用布局实际整数码值，按 level_low、level_high 交替，不能写 L/H 字符串。

两轴 floor 分格、row-major、四旋转与原坐标键完全沿用共享契约。网格采样中央 60% 宽和高；单排即使写 0.6，也继续旧采样路径，不裁掉纵向时序信息。填充不参与 payload、CRC、过渡拟合或 P10 统计。

1.0 缺整组扩展按旧单排读取；显式扩展必须完整有效。1.1 缺字段、类型/计数/索引/几何/矩形不符或未知几何拒绝，不回退单排。

pixel_format 允许实际平台渲染配置的确定性描述，作为不透明值比较。Mac 保留 BGRA8Unorm，Android 可记录实查 EGLConfig 属性描述；未知写 UNKNOWN 并保留诊断，不能以请求格式冒充实际或跨 API 归一化。calibration_key 增 geometry_profile，旧缺几何不能自动宣称网格兼容；纯坐标 tau 跨布局复用由模型消费者显式验证，不强制所有旧模型作废。

## 共同 fixture 与外部预期

共同文件为 [fixtures/cr-001-layouts.json](fixtures/cr-001-layouts.json)。它明确使用逻辑画布 121×109、动态区 [7,11,108,94]，只验证 placement，不是完整布局/会话，不含 markers，也不代替平台原边界回归。

文件有 24 例：四必需网格、两种旧单排，各四旋转，完整导出 modules/padding、矩阵、动态区和 drawable 尺寸。90°/270° drawable 为 109×121，其余为 121×109。独立锚点：F68-G6x12 首格 [7,11,15,24]，末数据格 [65,80,74,94]，90°首格 [85,7,98,15]。原 14 载荷向量复用，另固定 render_seq=1 的数据/填充/全部槽位码值 oracle；生成预期未调用产品编码器或 LayoutBuilder。

CR 提及的 reference/grid_layout_reference.py 未随所给路径提供，未声称已运行该脚本。共同 fixture 按协调者明确的输入和 CR 公式独立生成；由三端使用同一份字节验证。奇数格边长允许相差 1 像素，互补格数相等不等于像素面积严格相等。

相机静态/混合曝光图、人工 ROI、tau(u,v) 及 TRANSITION_FIT 的预期由 sync 消费者继续实现；Mac 保留模块绝对坐标，不产生伪造拟合日志。P10 4/6 像素、有效比例 95% 和光学精度仍是尚待实测的目标。

## Mac 后续串行实施

协调者核对并同步契约和 fixture 后，再依次实施下列产品改动。

| 顺序 | 文件范围 | 必需变化 |
| --- | --- | --- |
| 1 | OpticCore/Layout/LayoutBuilder.swift、布局测试 | 独立几何选择、整数二维分格与填充、1.1 JSON；保留原单排调用和 golden 预期，不改编码 payload enum |
| 2 | OpticDisplay/SceneBuilder.swift、场景测试 | 复用数据模块渲染，填满 padding；几何标定显示二维边界，互补标定覆盖填充；灰阶继续覆盖原动态区 |
| 3 | AppOptions.swift、SettingsView、SessionController.swift | CLI/UI 默认 F68-G6x12，保留显式 F68/C52；冻结几何配置，使预览、正式提交、标定一致；切换创建新布局/段 |
| 4 | Export/Calibration.swift、Scripts/validate_session.py、导出测试 | 新写 1.1，读旧单排/新网格，校验扩展和标定几何绑定，保持原六文件关联 |
| 5 | 现有测试、arm64 构建脚本 | 运行原测试与共同预期，离屏 Metal 回读数据与填充；FrameDriver 刷新及时间戳来源保持 |

产品实现串行进行；原 Runner、日志、刷新和分段继续回归。用户要求避免干扰桌面，默认只运行 CLI/headless 验证，不自动打开窗口或全屏。真实模式、长时运行和光学实验保留各自证据，不以软件构建或 placement 通过代替。
