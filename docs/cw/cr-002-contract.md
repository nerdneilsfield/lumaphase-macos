# CR-002 显示布局与诊断扩展契约

日期：2026-11-11。版本：1.2。范围：大 Tag 定位画面、全屏诊断、真实布局引用和模式切换。本文补充 OPTC-1 共享契约；未明确改变的编码、六文件、时间与事件语义继续沿用。跨相机的 `screen_geometry.json` 和辐射输入格式另行定稿，不由本文中的显示布局替代。

## 1. 版本与布局类型

采用本扩展的新会话，其 manifest.json、layout.json、display_profile.json 的 schema_version 统一写 "1.2"。旧 1.0、1.1 文件保持原值，读取行为不改变。

1.2 每个布局必须有字符串 layout_type，取值为 OPTC、CALIBRATION_TARGET、FULLSCREEN_DIAGNOSTIC。缺失或未知类型拒绝。合法 1.0、1.1 布局缺少此字段时按原 OPTC 解释；不得用它们表达本次新增的两类布局。

三类布局共同必填字段如下，类型和坐标规则沿用主契约：layout_id、layout_type、drawable_width_px、drawable_height_px、coordinate_system、pattern_rotation_deg、pattern_width_px、pattern_height_px、pattern_to_drawable。完整逻辑画布旋转后等于 drawable，矩阵为主契约3.2的纯旋转。所有导出矩形与顶点已处于最终 drawable 坐标，不再次旋转。

layout_type 区分真实布局的用途；geometry_profile 仍只表示 OPTC 模块的几何放置。不能把标定画面伪装为 F68/C52 模块布局。

| 类型 | 共同字段以外的必填字段 | 约束 |
| --- | --- | --- |
| OPTC | 主契约1.1全部布局字段 | 原 geometry_profile、modules、padding、markers、L/H 等保持不变 |
| CALIBRATION_TARGET | markers、reference_regions | 实际四个大 Tag 与实际静态参考区，无时间码模块 |
| FULLSCREEN_DIAGNOSTIC | diagnostic_pattern、level_low、level_high | 实际全屏图案，无 Tag，无时间码模块 |

CALIBRATION_TARGET 与 FULLSCREEN_DIAGNOSTIC 不得包含 layout_profile、geometry_profile、grid_rows、grid_cols、module_count、padding_count、module_order、sampling_inner_fraction、modules、padding 或 dynamic_rect_px。FULLSCREEN_DIAGNOSTIC 不包含 markers；缺少该字段明确表示这种类型没有标记，不把空列表扩展为普通 OPTC 的合法四标记几何。

CALIBRATION_TARGET 的 markers 使用主契约已有字段，ID0–3、字典和自身角序不变。reference_regions 为非空数组，每项为整数 index（从0连续）、rect_px（正面积整数半开矩形）、level（0–255整数）。参考区之间不重叠，与 Tag 黑框及白静区不重叠，全部位于 drawable 内。参考区外背景黑0，Tag 黑0、白255，参考块按自己的 level 实画。不额外导出虚构的载荷矩形。

## 2. 大 Tag 画面

固定 c_cal = 3 × c_run；c_run 为同一实际 drawable、图案旋转下原 RUN 构造器生成的 marker 整数 cell。黑框外边为6 × c_cal，四周白静区各至少 c_cal。ID和角序不变。两端可保留各自原布局边界，消费者必须用真实目标坐标，不按比例反推。

首版静态参考为0、128、255三个低频区域，具体整数边界逐项导出。大 Tag 布局与 RUN 布局使用不同的不可变 layout_id。不能为了塞入屏幕静默降低倍率；无法容纳四个 Tag、静区和正面积参考区时，明确提示不支持该尺寸，普通 RUN 保持可用。

CALIBRATE 和 RUN 沿用同一个实际输出窗口、drawable 尺寸、方向及完整坐标系。尺寸或方向改变时，旧映射需要重新验证；不得直接沿用。RUN 恢复原布局并保留原小 Tag，首版不增加隐藏 Tag 开关。

显示端大 Tag 页等待操作者明确继续，不用显示端100个提交帧或约3.33秒等待冒充相机100个唯一有效帧。相机侧记录逐路稳定性证据；无实测通过阈值时只报告测量结果，不能标稳定通过。

## 3. 全屏诊断图案

level_low 固定0，level_high 固定255。diagnostic_pattern 仅取以下值：

| 值 | 实际画面 |
| --- | --- |
| WHITE | 全 drawable 白255 |
| BLACK | 全 drawable 黑0 |
| CHECKERBOARD_2X2 | 逻辑画布按 floor(W/2)、floor(H/2) 分成2×2，左上和右下白，其余黑，再按图案矩阵变换 |
| VSYNC_BLACK_WHITE | 每次显示回调提交整幅单色；颜色按该次提交已分配的 native_frame_id 确定 |

这些画面不绘制 Tag、文字、状态卡或其他角落色块。操作控制层不覆盖测量画面。

VSYNC_BLACK_WHITE 会话中的 native_frame_id 必须为无前导零的非负十进制整数字符串。偶数提交白255，奇数提交黑0，按原身份字段的整数奇偶计算；ID由原分配器生成，不为诊断重置或另造计数。场景在分配该次身份后确定颜色，SUBMITTED 与之后结果事件引用同一身份。身份间隙或提交失败不补帧，不按最终确认排名重排颜色。实际呈现证据缺失仍保留原状态，不能据交替请求认定面板确实逐帧交替。

## 4. 模式、实验与会话记录

所有新增目标和诊断提交使用现有 frame_kind=CALIBRATION、phase=CALIBRATION；render_seq、payload_n、crc8 为 null。黑白交替不是 OPTC 状态，不消耗时间码序号。DYNAMIC 帧只能引用 OPTC 布局。呈现/失败/未确认结果始终保留原段与提交的 layout_id。

段的 layout_id 必须引用 layout.json 内当时实际布局。布局集合可以混合上述三类，旧布局不覆盖。段切换沿用 SEGMENT_ENDED/STARTED 的 CONFIGURATION_CHANGED 和已有 PHASE_CHANGED，不增加同义事件。

experiment_profile 使用以下共同名字；请求刷新率仍按实际选项单独保存在原段字段，不由名字冒充实际模式。

| 名称 | 画面与计划时长 |
| --- | --- |
| CR002-A-WHITE-SETTLE / CR002-A-WHITE | 白色先稳定等待1s，再计划采样3s |
| CR002-A-BLACK-SETTLE / CR002-A-BLACK | 黑色先稳定等待1s，再计划采样3s |
| CR002-A-GRID-SETTLE / CR002-A-GRID | 固定棋盘先稳定等待1s，再计划采样3s |
| CR002-B-BW | VSync黑白交替，计划60s |
| CR002-TAG | 大 Tag 定位，等待操作者明确继续 |

稳定等待和采样分别建段、共享相同真实静态布局，时长写原 planned_duration_ns。1s是首版操作默认，不是已测LCD稳定时间；实际显示区间以提交及呈现证据判断。A、B各自是独立会话。大 Tag 定位作为所选普通 RUN 会话的前置标定段，完成后创建原 RUN 布局的新段并继续原预热/开始卡/测量流程。原长曝光与原标定实验继续独立存在。

相机1/4/8ms、增益、WB、RAW/RGB采集及60s原始数据由外部调用者负责，显示应用不声称已设置相机。显示亮度、True Tone、Night Shift等未知值保持null或已有未知状态，不自动改系统设置。

非 OPTC 布局不套用原光学响应 calibration_key 的 geometry_profile 匹配；没有明确兼容验证时保持 IMPORTED_UNVERIFIED，不伪造 COMPATIBLE。读取器可加载混合会话，但非 OPTC 画面不得进入 payload 解码或被重建成合法时间码状态。独立的标定几何估计可以读取真实 CALIBRATION_TARGET 标记。

非 OPTC 显示仍是实际屏幕历史，读取器不能在建立保持区间前直接过滤掉这些提交。已确认的标定／诊断呈现截断前一 OPTC 状态的保持区间；可能改变画面但未确认的提交构成未知历史边界，不得把前一 OPTC 状态无证据地延长穿过它。曝光若跨越未知标定历史，不输出依赖该历史完整性的精细过渡时间。事件的 layout_id 必须与其原段及原提交一致，迟到的标定结果不能改挂到当前 RUN 段。1.2 的严格身份检查不得只覆盖网格而漏掉原单排。

## 5. 验证边界

三端至少检查：新旧版本分支、三类布局真实序列化/引用、非OPTC错误载荷字段拒绝、DYNAMIC引用限制、四旋转实际Tag与静区、全屏每个像素、诊断身份奇偶、原编码序号不被消耗、迟到结果仍引用旧布局。共同夹具及实现通过不等于四路原图检出率、100帧稳定或颜色响应实验通过。
