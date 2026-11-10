# macOS 实现计划与进度

日期：2026-11-10。用户已授权按现有设计实现，并指定两个 Orca OpenCode tab 参与；不重新启动设计审批。主 agent 负责接口、计划、集成和真实运行验证，代码实现串行进行。未经用户要求不提交、推送或删除文件。

## 目标和约束

实现 [macOS 设计](macos-design.md) 和 [OPTC-1 契约](optc-1-contract.md)：原生设置与全屏图案、F68/C52 编码、Metal 显示回调、四种实验配置、标定播放、逐帧日志和六文件会话导出。保持真实系统呈现时间与预计时间分离；缺标定不生成虚假的光学精度。相机采集和后端拟合不在本工程内。

仓库初始无源码，仅有 LICENSE、.gitignore、未跟踪 docs/ 与 .cw/。本机 Xcode 27.2、Swift 6.4.2、arm64 macOS 27.2；部署目标 macOS 14。优先无外部依赖的 Swift Package 加本地 app bundle 脚本；最终工程方式待 SDK 探索确认。不覆盖初始文档或 Counterweight 配置。

## 执行任务

| 任务 | 所有者 | 输入 | 可观察结果 | 状态 | 依赖 / 次数 |
| --- | --- | --- | --- | --- | --- |
| E1 平台与工程探索 | tab 23610d96（term_f2c25e43） | Mac 设计、本机 SDK | 准确 Metal API、时钟来源与可执行构建方式 | accepted | 无 / 1 |
| P1 只读接口规划 | tab a064de00（term_655b6331） | 两份设计契约 | 编码、布局、记录与 UI 的具体接口和验证方案 | accepted | 无 / 1 |
| T1 协议、布局、会话数据 | tab a064de00（term_655b6331） | P1 与现有协议向量；独立于 Metal | 向量一致；65536 载荷与 UInt64 边界；导出关联和缺失语义正确 | accepted | P1 / 2 |
| R1 T1 独立审阅 | 主 agent | T1 代码与输出 | 核实契约差异并修复实质问题 | accepted | T1 / 1 |
| T2 Metal、原生 UI 和应用链路 | tab a064de00（term_655b6331） | T1 接口及设计 | 本机可运行应用，真实短会话确认呈现并导出六文件 | accepted | R1 / 完成 |
| R2 全应用审阅 | tab 23610d96（term_f2c25e43） | 完整源码和会话输出 | 行为与契约差异清单，必要修复后重检 | accepted | T2 / 2 |
| V1 主 agent 集成验证 | 主 agent | 构建、测试、真实应用 | 编码/分段检查通过，实际 Metal 图案及日志经独立核对 | accepted，限下述证据范围 | R2 / 完成 |

## 验证重点

编码预期来自原设计的 `validation/protocol_test_vectors.json`；布局与日志预期来自公共契约。真实屏幕验证必须使用 CAMetalDisplayLink 和呈现回调，不能用模拟日志替代。UI 确认可见图案、会话开始/结束和导出；脚本核对 JSON 类型、时间差、每个确认事件的提交身份、所有段布局保留、未确认原因及摘要计数。

恢复或尺寸变化分段保留旧身份与布局，新动态提交消耗新序号。封存后不修改包。日志和追踪容量有界，溢出明确标记，不在渲染线程等待磁盘。GPU 统计仅使用有明确语义的计时；latch 无公开查询能力时 UNSUPPORTED。

资源密集命令通过 `rtk lim -c 0-3 -m 4G -- ...`；macOS 下 lim 的限制能力按其实际提示报告。协议/格式检查与本机显示运行分开记录，光电精度验收不在软件运行中伪造。

## 当前记录

已通过 Orca run_8898215d51ec 向两个指定 tab 分派只读探索与规划。后续按其查证结果固定新文件和接口，再分派一个实现任务；另一 tab 审阅，不并发实现。

P1 已回报只读方案。采用离线 Swift Package，`OpticCore` 纯 Foundation 模块，`OpticDisplay` 和 `LumaphaseApp` 在 T2 加入；以 Swift 5 语言模式隔离尚无 Sendable 标注的平台 delegate，部署 macOS 14，不引入外部依赖。T1 创建 Package.swift、Sources/OpticCore/ 和 Tests/OpticCoreTests/，后续任务引用其实际公开接口；UI 不依赖测试内部实现。

T1 包含编码、整数布局与旋转、独立时间字段状态、逐段配置、不可变帧身份、串行事件归并、有界日志写入/溢出锁存和六文件目录导出。协议向量复制为测试资源，原文件不修改。API 细节允许执行者在该模块内选择并在回报中列出，但公共数据键名和类型完全按现有契约。验证用 swift test（4 jobs 以内），测试预期来自外部向量/契约。

平台决定：应用帧身份始终使用 native_frame_id；Mac 的 drawable_id 不作唯一索引，layer 重建不会影响关联。GPU 提交后失败仍保留 SUBMITTED，并写 operation=MTLCommandBuffer.status 的 RENDER_FAILURE，禁止伪造呈现；无效呈现按原契约保留。Mac 无法通过公开 API 读取的亮度/显示功能写 null/UNKNOWN，用户手动修改这些设置需停止并重开段，不能宣称自动检测。显示旋转优先由公开 API 实际语义映射，无法确认则 null，原始值保留。

主 agent 已重跑 T1 的 `swift test --jobs 4`：41 tests / 0 failures；独立 Python 样例校验：2768 checks 通过。审阅发现 EventLog 解锁后异步入队可能导致并发批次与 flush 乱序，以及提前无效回调直接写 UNCONFIRMED 会早于 SUBMITTED；已由原实现者修正，待复核后接受。lim 本机未安装，Swift 编译显式限制为 4 jobs；尚未具备内存 cgroup 限制，未执行重型实验。

E1 终端仍在工作但出现 provider HTTP 524 重试，已发一次限定范围消息，要求先回报已有证据而不继续扩大探索。未中断或重启该进程。

T1 修正已接受：EventLog 在锁内只异步投递批次、解锁后同步屏障；提交前有效与无效回调均缓冲至 SUBMITTED 之后。主 agent 已读关键修法并重跑 46 tests / 0 failures。T2 已交可用 tab 继续，主 agent 取得官方 ArUco 数据并保留独立验收工作；E1 的 provider 失败不阻塞纯代码集成。

E1 已完成 SDK 核查与临时真实 Metal 探针，报告位于 `/private/var/folders/sj/34br26nn0k558dd541dvb02r0000gn/T/opencode/e1/report-e1-macos-explore.md`。当前公开模式只报告 60 Hz；不能宣称已运行 M59-S1 的 59.94 Hz。主 agent 实际解析两份原始探针文件：第一次 239/240 有效（帧 1 为零），第二次 238/240 有效（帧 1 和 18 为零），纠正报告“均239”的数字；中位呈现间隔均约 16.666708 ms。GPU 与呈现字段为 host 秒，callback 到达时刻不是呈现时刻。主 agent 已取得固定 OpenCV 4.10.0 源，独立核对前 4 个标记的 0°/90°字节，把 8 字节数据及许可证保存到 third_party/opencv-4.10.0，不新增运行时依赖。

独立 R1 报告 `/private/var/folders/sj/34br26nn0k558dd541dvb02r0000gn/T/opencode/r1-opticore-review.md` 指出容量满帧未保留提交记录，后续真实有效回调被丢弃；主 agent 核查路径后要求唯一 T2 实现者修复并加早到/迟到容量满测试。同时要求 SessionPackage 三个 add 入口在 finished 后用已有 alreadyFinished 错误拒绝改写，保持封存不变。未采纳无当前故障证据的内存结构重构建议；应用实现期间不并行改 Core。

T2 已回报可运行原生应用与 60 tests，四份真实 Metal 导出。主 agent 独立重跑 smoke+resize+pause 样例（101022 checks）和 C52/90°样例（73206 checks）的校验均通过。已实际打开设置界面，见四配置/图案参数/输出目录/标定/实际60Hz信息；因实现者重建bundle和smoke抢前台，人工按钮验证暂待其结束。

主 agent 收尾发现并交 T2 原实现者修：render_complete 未消费已可取得的 gpuEndTime；summary 尚无原设计要求的CPU/GPU/呈现间隔分布；容量满补记新加64条环仍可能丢真实证据，early-valid分支未减封存pending计数；README 的 model byte-for-byte 应为 JSON 语义保留。这些完成后再接受 T2，不将已有自动smoke当成全屏人工链路验证。

用户运行偏好（本会话后续持续生效）：computer use 和窗口/全屏验证干扰日常工作，停止主动 UI 操作或启动前台 smoke。后续只用 CLI、无界面测试和已有导出日志；两个 worker 均已通知。主 agent 此前已完成原生全屏短会话（1008提交/1001确认/7未确认）、手动窗口模式暂停恢复新段并停止（1957/1948/9），分别通过独立校验 236594 与 464724 项，并实际看到 F68 静态预览；不再重复这些前台实验。

GPU收尾已回报完成：真实短会话318条结果均有 gpuEndTime 原始秒和VALID render_complete，timing包含三类延迟；主 agent 重跑测试53 Core + 10 Display均通过，重验GPU样例75816项通过。R2最终只读审阅仍待回报，呈现间隔统计尚待最小补齐。

R2报告已收到（`/private/var/folders/sj/34br26nn0k558dd541dvb02r0000gn/T/opencode/r2-final-review.md`）。主 agent 裁决并交唯一实现者完成最后一次限定修订：按段排序真实呈现求间隔统计、帧级统计去重；正常退出异步停止并封存；忙碌时冻结配置/标定操作；暂停resize不建空段；各显示阶段的模式/尺寸变化和休眠/唤醒/退出全屏处理；固定具名sRGB空间；原始零旋转写标准0。预览黑屏属于推断，主 agent已观察到完整静态F68，未采纳连续刷新改动；立即取消可为空会话，不伪造采集。实现者只准无界面检查，另一tab等待限定复核，不重复审查已通过的正常会话。

最终主 agent 重跑 `swift test --jobs 4`：55 Core + 11 Display 共66项通过，无失败；离屏 Metal 32/224/0/255码值读回实际执行通过，无跳过。新增呈现间隔与去重的合成会话校验2827项通过。AppKit最后一轮退出/休眠/resize修法只编译与只读检查，按用户偏好未再启动前台实测；不将早先真实运行当成最新生命周期修法的运行证据。当前仅剩限定复核和独立目录打包；主 agent要求移除未经需求的6s强制退出watchdog，正常退出必须等待现有导出回调。

打包脚本由主 agent 最小调整：支持第二输出目录，去掉先删整个目标目录的步骤，签名失败不再吞掉。最终包放 `.build/verified/Lumaphase.app`，不启动、不替换运行中的旧包。默认入口与可选路径已写 README。

## 完成记录

限定复核报告 `r2b-limited-fix-review.md` 确认退出封存、暂停resize、所有阶段尺寸保护、配置快照与sRGB等修法无阻断问题。主 agent另修最后全屏条件：挂起重建不再要求尺寸不同；尺寸回调保留FULLSCREEN_EXIT原因；退出全屏立即停止旧段提交。最终 `swift test --jobs 4` 再次55 Core + 11 Display全过，离屏码值读回0.027 s真实执行，无跳过。合成导出独立校验2827项通过；最终打包只构建到独立verified目录，未启动窗口。

最终交付是现有工作区内的未提交源码、README与 `.build/verified/Lumaphase.app`；未修改既有契约和其他仓库，未提交/推送/发布/删除工作区文件。所有Orca任务已回报结束，两个用户指定tab保持可用。

验证边界：早先真实Metal会话和人工正常全屏/暂停恢复/停止证明了主要链路；最后生命周期修订、固定sRGB和全屏标签修正经过编译、headless测试及只读复核，未重跑GUI。尚未进行相机实拍识别、光电时间精度、59.94/120 Hz物理模式与20 min长时实验；本机实际模式约60Hz。Swift 5语言模式仍有平台delegate actor隔离编译警告，已固定delegate到main runloop，未宣称Swift6语言模式可用。按用户要求，后续不自动启动前台验证。
