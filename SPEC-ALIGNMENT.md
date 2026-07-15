# UI 规约对齐与验证矩阵

`ui/Markdown Viewer.dc.html` 是界面布局、视觉状态和交互细节的唯一设计真相源。
`AGENTS.md` 记录产品定位和已经拍板的业务交互，代码记录实现细节，本文件记录当前实现范围、直接验证入口和真实 App 证据边界。
本文件不绑定分支、提交号、发布版本或固定测试数量，因为这些信息会快速失效。
任何一次构建或测试是否通过，都以该次命令输出及其生成的证据文件为准。

## 当前实现基线

| 范围 | 当前实现与主要代码 | 直接自动验证 | 当前真实 App 证据边界 |
|---|---|---|---|
| 设计真相源 | 生产界面以 `ui/Markdown Viewer.dc.html` 为准，参考捕获器位于 `scripts/visual/`。 | `Tests/Visual/VisualToolTests.sh` 校验权威 HTML 哈希、截图绑定、状态断言、几何锚点、严格像素合同和验收失败路径。 | 默认 passive 生成三个尺寸乘七个状态的 21 对真实 App 证据；严格比较器自动校验状态、非文字几何、全帧像素比例与空间差异。 |
| 文档模型 | `Sources/MarkdownViewer/Documents/MarkdownDocument.swift` 使用稳定 UUID 和无损源码切片，保留混合换行、空白、围栏和无末尾换行。 | `Tests/MarkdownViewerTests/MarkdownDocumentTests.swift`。 | 静态截图只能证明 fixture 被真实 App 打开，不能证明 round-trip 或局部重解析。 |
| 块级编辑 | `Sources/MarkdownViewer/Editor/BlockEditorStore.swift`、`Sources/MarkdownViewer/Editor/BlockSourceEditor.swift` 和 `Sources/MarkdownViewer/Editor/MarkdownBlockEditorView.swift` 提供单块源码编辑与提交。 | `Tests/MarkdownViewerTests/BlockEditorStoreTests.swift`、`Tests/MarkdownViewerTests/BlockSourceHighlighterTests.swift` 和 `Tests/MarkdownViewerTests/BlockSourceLifecycleTests.swift`。 | passive 在三个尺寸确定性捕获真实原生源码编辑器、选区和可见性；`palette-find` bounded batch 还真实点击首块、输入 marker 并在打开 palette 前提交。其他编辑命令仍缺逐项真实 App 覆盖。 |
| 编辑命令 | `Sources/MarkdownViewer/Documents/MarkdownEditingCommands.swift` 处理 Enter、Backspace、Tab、Shift+Tab、上下边界移动和常用行内格式快捷键。 | `Tests/MarkdownViewerTests/MarkdownEditingCommandsTests.swift`。 | `editor-structure` 已规划引用与列表结构命令；`editor-boundaries` 已规划上下边界移动、斜体、行内代码、块首 Backspace 合并和 Esc 提交。后者的计划、harness 和单元用例已离线通过，但当前源树匹配的真实 App 动作证据仍待运行。 |
| 表格编辑 | `Sources/MarkdownViewer/Editor/MarkdownTableGridEditor.swift` 和 `Sources/MarkdownViewer/Documents/MarkdownDocument.swift` 提供单元格编辑、焦点移动、增删行列和对齐序列化。 | `Tests/MarkdownViewerTests/BlockEditorStoreTests.swift`、`Tests/MarkdownViewerTests/MarkdownDocumentTests.swift` 和 `Tests/MarkdownViewerTests/MarkdownTableLifecycleTests.swift`。 | passive 在三个尺寸验证真实网格、首个表头焦点、177 pt 网格高度、可见性和确定性滚动；`table-controls` 已规划编辑与工具栏操作，`table-navigation` 已规划 Tab、Shift+Tab、Return、末格自动增行和精确焦点序列。后者的计划、harness 和单元用例已离线通过，但当前源树匹配的真实 App 动作证据仍待运行。 |
| 被动格式化 | `Sources/MarkdownViewer/Editor/MarkdownBlockRenderer.swift` 和 `Sources/MarkdownViewer/Editor/PassiveMarkdownFormatting.swift` 渲染块结构和行内 token。 | `Tests/MarkdownViewerTests/PassiveMarkdownFormattingTests.swift` 和 `Tests/MarkdownViewerTests/MarkdownDocumentTests.swift`。 | fixture 基线截图包含多种格式，但没有逐格式交互断言，因此不能据此声称全部格式 E2E 通过。 |
| 代码、任务、链接和脚注 | `Sources/MarkdownViewer/Editor/MarkdownBlockRenderer.swift` 和 `Sources/MarkdownViewer/Editor/MarkdownBlockEditorView.swift` 实现复制、任务切换、链接反馈和脚注行为。 | `Tests/MarkdownViewerTests/PassiveMarkdownFormattingTests.swift`、`Tests/MarkdownViewerTests/MarkdownDocumentTests.swift` 和 `Tests/MarkdownViewerTests/BlockEditorStoreTests.swift` 验证相关模型、格式化、持久化 AX 链接和目标任务切换序列。 | `preview-content` 已规划预览内真实任务点击、Bash 代码卡 hover、复制点击、精确剪贴板校验与原样恢复；`preview-footnotes` 已规划脚注引用 hover、物理点击、定义跳转和返回。两者的离线 plan 与 harness 均通过，但当前源树匹配的真实 App 动作证据仍待运行，普通外链点击仍未覆盖。 |
| 纯预览 | `Sources/MarkdownViewer/Documents/DocumentManager.swift`、`Sources/MarkdownViewer/Shell/EditorHeader.swift`、`Sources/MarkdownViewer/Editor/MarkdownBlockRenderer.swift` 和 `Sources/MarkdownViewer/App/App.swift` 在同一文档页面切换预览状态，禁用块源码与表格网格编辑，同时保留代码复制、任务切换、链接和脚注交互。 | `Tests/MarkdownViewerTests/DocumentFormatTests.swift`、`Tests/MarkdownViewerTests/PreviewInteractionTests.swift`、`Tests/MarkdownViewerTests/PassiveMarkdownFormattingTests.swift` 和 `Tests/MarkdownViewerTests/LaunchConfigurationTests.swift`。 | passive 在三个尺寸走生产预览切换并捕获真实 1.6 秒产品 toast；`preview-content` 与 `preview-footnotes` 分别规划预览内任务和代码交互以及脚注导航，当前仅离线验证通过，当前源树匹配的真实动作证据仍待运行。 |
| 即时查找替换 | `Sources/MarkdownViewer/Find/BlockFindEngine.swift`、`Sources/MarkdownViewer/Find/FindState.swift` 和 `Sources/MarkdownViewer/Find/FindBarView.swift` 搜索可见文本并支持替换。 | `Tests/MarkdownViewerTests/BlockFindEngineTests.swift`、`Tests/MarkdownViewerTests/BlockEditorStoreTests.swift` 和 `Tests/MarkdownViewerTests/PlainSourceFindCoordinatorTests.swift`。 | passive 在三个尺寸捕获空 query 的真实面板和几何；`palette-find` 有历史导航证据。`find-options` 与 `find-regex-replace` 已规划大小写、全词、正则捕获组、单次替换和全部替换，计划、harness 和单元用例已离线通过，但当前源树匹配的真实 App 动作证据仍待运行。 |
| 内容大纲 | `Sources/MarkdownViewer/Outline/OutlineRailView.swift` 和 `Sources/MarkdownViewer/Editor/MarkdownBlockEditorView.swift` 提供左侧大纲、当前项和跳转。 | `Tests/MarkdownViewerTests/OutlineStatusPolicyTests.swift`。 | passive 验证三个尺寸的静止大纲几何；`outline-navigation` 已规划真实 hover 展开、精确 AX 标题点击、300 ms 跳转与 900 ms wash 的峰值、渐隐和清除证据。离线 plan、harness 和策略单元测试通过，当前源树匹配的真实 App 动作证据仍待运行。 |
| 文件侧栏 | `Sources/MarkdownViewer/Sidebar/SidebarView.swift` 和 `Sources/MarkdownViewer/Documents/DocumentManager.swift` 提供目录树、名称与相对路径过滤、键盘导航、调宽和隐藏，并为 workspace-relative 行、空结果、resize handle 与侧栏 surface 提供稳定 AX ID。 | `Tests/MarkdownViewerTests/AccessibilitySurfaceTests.swift`、`Tests/MarkdownViewerTests/DocumentManagerLifecycleTests.swift`、`Tests/MarkdownViewerTests/SessionStoreTests.swift` 和 `Tests/E2E/RealAppHarnessTests.sh` 覆盖稳定 ID、计划预算、严格 session、diagnostic、AX 序列与合成 fixture 失败路径。 | passive 在三个尺寸验证 fixture 行、active 行、active tab 与 sidebar-hidden；`sidebar-filter-navigation` 规划真实过滤与键盘打开，`sidebar-layout-controls` 使用两段独立前台阶段覆盖文件夹折叠展开、两端 resize clamp 和整体隐藏恢复。离线 plan、aggregate、harness 和 verifier 通过，当前源树匹配的真实 App 动作证据仍待运行。 |
| 标签页和文件生命周期 | `Sources/MarkdownViewer/Documents/DocumentManager.swift`、`Sources/MarkdownViewer/Documents/DocumentModels.swift` 和 `Sources/MarkdownViewer/Shell/EditorHeader.swift` 提供多标签、脏标签确认关闭、相邻标签、恢复关闭标签、活动原生编辑器保存同步和基于原始字节基线的外部冲突拒绝。 | `Tests/MarkdownViewerTests/DocumentManagerLifecycleTests.swift`、`Tests/MarkdownViewerTests/BlockSourceLifecycleTests.swift`、`Tests/MarkdownViewerTests/MarkdownTableLifecycleTests.swift`、`Tests/MarkdownViewerTests/PlainSourceFindCoordinatorTests.swift` 和 `Tests/E2E/RealAppHarnessTests.sh` 覆盖原生编辑器、marked text、冲突、canonical 与 symlink、Save As、编码和严格合成 verifier。 | `save-lifecycle` 规划 `1180x760` 下的块、表格、纯源码、打开后外部修改、dirty Session、Save As 和 diagnostic；当前树已用隔离 profile 的可见真实 App 手工验证这些 Goal 2 路径，bounded driver 在首动作前被输入干扰守卫终止，因此不把该次批次记为自动动作通过。 |
| 会话恢复 | `Sources/MarkdownViewer/Documents/SessionStore.swift` 和 `Sources/MarkdownViewer/Documents/DocumentModels.swift` 保存标签、无损块、dirty 内容、磁盘字节基线、活动标签、字号、侧栏、目录展开和滚动位置；clean 恢复重读磁盘，dirty 恢复保留草稿与原基线。 | `Tests/MarkdownViewerTests/SessionStoreTests.swift`、`Tests/MarkdownViewerTests/DocumentManagerLifecycleTests.swift` 和 `Tests/E2E/RealAppHarnessTests.sh` 覆盖 session 迁移、可信与未知基线、正常终止合同、严格重启 verifier 与失败路径。 | `tab-session-lifecycle` 规划完整 session 交互；Goal 2 的隔离真实 App 验收已验证 dirty Session 外部修改阻止普通保存并保留草稿、dirty 和原文件。 |
| 文件格式 | `Sources/MarkdownViewer/Documents/DocumentFormat.swift` 把 `.md`、`.markdown` 和 `.mdx` 归为 Markdown，并把支持的源码扩展名归为纯源码；保存沿用 UTF-8 BOM、原换行格式和末尾换行状态。 | `Tests/MarkdownViewerTests/DocumentFormatTests.swift`、`Tests/MarkdownViewerTests/DocumentManagerLifecycleTests.swift` 和 `Tests/MarkdownViewerTests/PlainSourceFindCoordinatorTests.swift`。 | Goal 2 的隔离真实 App 验收已验证非 Markdown 源码直接保存，以及切换后 `state.json` 和可见 Debug HUD 立即显示当前纯源码文档；系统拖放仍不属于本次范围。 |
| 命令面板 | `Sources/MarkdownViewer/Palette/CommandPalette.swift` 和 `Sources/MarkdownViewer/App/App.swift` 提供文档和命令入口。 | `Tests/MarkdownViewerTests/CommandPaletteTests.swift`。 | passive 在三个尺寸用同一个生产面板视图捕获 inline ordered-out 状态；`palette-find` batch 覆盖 Command+K、双 Shift、文本过滤、hover、键盘选择、Enter 和 backdrop 关闭。 |
| 性能隔离 | `Sources/MarkdownViewer/Editor/BlockEditorStore.swift` 记录解析次数、局部 mutation 次数和按块 revision，`Sources/MarkdownViewer/App/DebugDiagnosticSnapshot.swift` 记录真实 block renderer view-update 回调。 | `Tests/MarkdownViewerTests/BlockEditorPerformanceTests.swift` 和 `Tests/MarkdownViewerTests/DebugDiagnosticSnapshotTests.swift`。 | 真实 App 结构化 snapshot 导出进程内累计的总计和按块 UUID 计数，但这些计数不是 WindowServer paint 或屏幕像素 redraw。 |
| Debug 隔离 | `ui/格式示例.md` 是格式 fixture 的唯一实体真相源，`Sources/MarkdownViewer/App/AppEnv.swift`、`Sources/MarkdownViewer/App/DebugFixtureLoader.swift`、`Sources/MarkdownViewer/App/DebugDiagnosticSnapshot.swift`、`scripts/build-debug.sh` 和 `scripts/run-debug.sh` 只把它的逐字节副本放入 Debug bundle，并使用独立 session、临时 workspace、当前活动文档约束的诊断 snapshot、PID marker 和 crash 目录。 | `Tests/MarkdownViewerTests/DebugFixtureTests.swift`、`Tests/MarkdownViewerTests/LaunchConfigurationTests.swift`、`Tests/MarkdownViewerTests/DebugDiagnosticSnapshotTests.swift` 和 `Tests/E2E/BuildDebugIncrementalTests.sh`。 | 所有 E2E tier 都读取同一源 fixture 并经 `run-debug.sh --background` 启动；Goal 2 真实 App 证据还直接检查非 Markdown 的 `state.json` 与 HUD 一致，且非活动 Markdown 回调不能覆盖当前诊断。 |
| USER 隔离 | `scripts/build.sh` 和 `scripts/release-smoke.sh` 让 Release 忽略 Debug 参数，并排除格式 fixture、`.dc.html` 与 `support.js`。 | `./scripts/release-smoke.sh`。 | Swift Package 只处理 `Resources/`，不会把 `ui/格式示例.md` 或设计预览资源编入 Release；Release smoke 是隔离 USER 启动检查，不是 Debug App E2E。 |

## 已拍板的产品偏差与解释

- 使用系统原生窗口控制按钮，不在内容层伪造红黄绿按钮。
- 首次启动只创建一个空白未命名文档，设计稿中的示例文件只用于隔离的 Debug 视觉工作区。
- 新打开的文件夹默认展开以匹配当前终稿，恢复会话时使用保存的展开状态。
- 大纲位于内容画布左侧，而文件侧栏仍位于窗口最左侧。
- 查找在输入时立即重算，Return 和 Shift+Return 只负责结果导航。
- `.mdx` 与 `.md`、`.markdown` 使用同一块级渲染和编辑体验。
- 纯预览是同一文档页面的无编辑器状态，不是单独预览窗格；代码复制、任务切换、链接和脚注导航继续可用。

## 验证层级

### 1. Swift 单元、模型、格式化和性能测试

```bash
./scripts/test.sh
```

可以把额外 SwiftPM 参数继续传给脚本，例如：

```bash
./scripts/test.sh --filter MarkdownDocumentTests
```

E2E harness、增量 Debug 构建与隔离启动身份的基础设施回归入口是：

```bash
bash Tests/E2E/RealAppHarnessTests.sh
bash Tests/E2E/BuildDebugIncrementalTests.sh
bash Tests/E2E/RunDebugLaunchIdentityTests.sh
```

前两项不启动 Markdown Viewer，启动身份回归只打开隔离的 background Debug 实例。

### 2. Debug 构建与确定性视觉 fixture

```bash
./scripts/build-debug.sh
./scripts/run-debug.sh --reset --visual-test-hide-hud
```

默认视觉配置使用 `1180x760` 窗口和 `格式示例.md`。
Application Support、session、临时 workspace、PID marker 和 crash-only 日志目录都位于独立 profile。
正常日志只保存在内存 ring buffer 中，只有 crash 才尝试写入 profile 的 `Logs/crash/`。
更多参数见 `./scripts/run-debug.sh --help`。

Debug HUD 持续提供当前文档、活动块 UUID 与类型、编辑或预览模式、源码 selection、活动表格单元格、dirty、find、outline、scroll、session 路径、parse 次数、local mutation 次数和 block renderer view-update 次数。
隔离 Debug 视觉 profile 会把最新状态原子写入 `Profile/Diagnostics/state.json`，其中 `Profile` 是 `--visual-test-root` 指定的根目录。
结构化 schema 包含可为空的 `blockID` 与 `blockType`，带 `location` 与 `length` 的 UTF-16 `selection`，带 `row` 与 `column` 的 `activeTableCell`，以及当前 `document`、`mode`、`dirty`、`scrollY`、`sessionPath`、计数和 `updatedAt`。
`find` 包含 `query`、`display`、`matchCount`、`currentIndex`、`invalidRegex`、`replaceExpanded`、`caseSensitive`、`wholeWord` 和 `regex`，`outline` 包含 `headingCount` 和 `activeIndex`。
`renderedBlockUpdateCount` 是当前 App 进程累计的 block renderer view-update 回调总数，`activeBlockRenderUpdateCount` 是当前活动块的累计数，`renderedBlockUpdates` 是按 block UUID 汇总的累计计数。
这些计数在隔离 profile session 的当前 App 进程生命周期内持续累加，并在新进程启动时重新开始。
这些字段是实际 renderer update 证据，但不是 WindowServer paint、合成次数或屏幕像素 redraw 计数。
local mutation 次数也不等同于 renderer update 或屏幕重绘次数。
`--visual-test-hide-hud` 只隐藏 HUD 像素，不关闭 Debug instrumentation。
E2E harness 会等待目标状态，检查精确顶层 schema、目标文档、隔离 session 路径和非空正数 renderer 计数，并把带标签的 snapshot 复制到每个尺寸的 evidence manifest。
没有隔离视觉 profile 的 Debug 启动和所有 Release 启动都不会写这个 snapshot 文件。

### 3. 原生应用 E2E

```bash
./scripts/e2e/run-real-app-e2e.sh
./scripts/e2e/run-real-app-e2e.sh --foreground-smoke
./scripts/e2e/run-real-app-e2e.sh --foreground-batch table-controls
./scripts/e2e/run-real-app-e2e.sh --foreground-batch editor-structure
./scripts/e2e/run-real-app-e2e.sh --foreground-batch editor-boundaries
./scripts/e2e/run-real-app-e2e.sh --foreground-batch table-navigation
./scripts/e2e/run-real-app-e2e.sh --foreground-batch find-options
./scripts/e2e/run-real-app-e2e.sh --foreground-batch find-regex-replace
./scripts/e2e/run-real-app-e2e.sh --foreground-batch preview-content
./scripts/e2e/run-real-app-e2e.sh --foreground-batch preview-footnotes
./scripts/e2e/run-real-app-e2e.sh --foreground-batch outline-navigation
./scripts/e2e/run-real-app-e2e.sh --foreground-batch sidebar-filter-navigation
./scripts/e2e/run-real-app-e2e.sh --foreground-batch sidebar-layout-controls
./scripts/e2e/run-real-app-e2e.sh --foreground-batch tab-session-lifecycle
./scripts/e2e/run-real-app-e2e.sh --keyboard-only
./scripts/e2e/run-real-app-e2e.sh --extended-full-pointer
```

默认 passive tier 只需要屏幕录制权限，始终经 `run-debug.sh --background` 启动，并且不发输入、不激活 App、不移动鼠标、不调用 `reset-sidebar-filter`。
它在 `1180x760`、`860x560` 和 `1440x900` 分别捕获 `default`、`palette`、`find`、`preview`、`sidebar-hidden`、`source-editor` 和 `table-editor`，每个 pair 使用独立 profile 和 PID。
这七个状态是验证稳定渲染与几何的 Debug launch-state 预置，不是用户通过点击、输入、hover 或拖拽到达状态的动作证据。
passive 侧栏检查强制使用 `sidebar --passive` 和 Vision OCR，不能因为已有辅助功能权限而切换到会激活窗口的路径。
每次进程启动前到退出后都有 activation notification 加约 25 ms frontmost 采样的生命周期观察器。
被测 Debug App 任何时刻成为前台、窗口出现在屏幕上、观察器提前退出或进程生命周期前后的鼠标坐标不同都会失败，包括用户在运行期间把鼠标留在不同位置。
开发迭代可用 `--probe-sizes` 和 `--probe-states` 只运行选定 canonical pairs。
probe 执行所选尺寸与状态的笛卡尔积；只指定一个 filter 时，未指定的轴保留完整 canonical 列表。
任意显式 probe filter 都让证据固定标为 `runScope=development-probe` 与 `strictVisualAcceptanceEligible=false`，即使显式枚举完整矩阵也不能替代未过滤的 21-pair 验收。
`--foreground-smoke` 是 `--foreground-batch palette-find` 的别名，只运行 `1180x760`，覆盖块点击与提交、Find、双 Shift、palette hover 和键盘操作。
该 suite 拆分为 `block-find` 与 `palette-keyboard` 两段独立 foreground driver call，保守估算分别为 2190 ms 和 1690 ms，每段单独受 4000 ms 硬上限与最后 400 ms 清理保留约束。
第一段恢复桌面后，runner 在后台验证并快照已提交 marker、字号、Find query、全词和替换展开状态。
第二段先重复 `Command+F`，明确重建 Find 已打开且聚焦的阶段前置状态，再执行双 Shift、palette 过滤、hover、键盘选择、字号快捷键和 backdrop 关闭。
严格 aggregate 要求完整动作序列、恰好两次 activation、两段无干扰、两次 focus 与 pointer restore、相同 PID 与隔离 session，以及中间和最终 session/diagnostic 状态。
`--foreground-batch table-controls` 从阅读态表格真实点击进入网格，覆盖输入、Tab、对齐、增删行列和 Esc，且使用独立 profile 与同样的 4 秒预算。
`--foreground-batch editor-structure` 从阅读态引用和列表真实点击进入源码编辑器，覆盖续行、Tab、Shift+Tab、粗体、Esc、undo 和 redo，且使用独立 profile 与同样的 4 秒预算。
`--foreground-batch editor-boundaries` 从精确阅读态块进入源码编辑器，覆盖上下边界移动、斜体、行内代码、块首 Backspace 合并和 Esc 提交，使用同样的固定 4 秒预算。
`--foreground-batch table-navigation` 从阅读态表格进入网格，覆盖 Tab、Shift+Tab、Return、末格自动增行、精确焦点序列和 Esc 提交，使用同样的固定 4 秒预算。
`--foreground-batch find-options` 在受控文本中覆盖 query 聚焦、大小写敏感和全词选项，使用同样的固定 4 秒预算。
`--foreground-batch find-regex-replace` 在受控文本中覆盖正则捕获组、当前项替换、剩余项全部替换和精确最终源码，使用同样的固定 4 秒预算。
`--foreground-batch preview-content` 在 scroll 1600 通过快捷键进入纯预览，真实点击任务，hover 并点击 Bash 代码复制，精确校验剪贴板内容并原样恢复，再通过快捷键返回编辑。
`preview-content` 的保守前台估算为 2.00 秒，并使用同样的固定 4 秒预算与最后 400 ms 清理保留。
`--foreground-batch preview-footnotes` 在 scroll 3000 通过快捷键进入纯预览，移动并物理点击第一个脚注引用，跳转到定义，点击原生返回按钮，再通过快捷键返回编辑。
`preview-footnotes` 的保守前台估算为 2.76 秒，并使用同样的固定 4 秒预算与最后 400 ms 清理保留。
`--foreground-batch outline-navigation` 在 scroll 650 使用真实 hover 展开左侧大纲，通过精确 AX ID 物理点击第 12 个 heading，并捕获 300 ms 跳转中、900 ms wash 峰值、渐隐和完全清除状态。
`outline-navigation` 的保守前台估算为 3.21 秒，并使用同样的固定 4 秒预算与最后 400 ms 清理保留。
`--foreground-batch sidebar-filter-navigation` 通过精确 AX ID 聚焦侧栏筛选，覆盖名称、相对路径和空结果，使用 Down、Up 与 Return 打开 README 并返回 fixture，最后清空 query 并保持筛选框焦点。
`sidebar-filter-navigation` 的保守前台估算为 3.15 秒，并使用同样的固定 4 秒预算与最后 400 ms 清理保留。
`--foreground-batch sidebar-layout-controls` 通过精确 AX ID 折叠和展开 `docs`，第一段拖动 resize handle 命中 176 pt clamp，第二段从已验证的 176 pt 窗口坐标拖到 440 pt clamp，再用 `Command+\` 隐藏并恢复整个侧栏。
`sidebar-layout-controls` 拆分为 `collapse-minimum` 与 `maximum-toggle`，保守前台估算分别为 1450 ms 和 1690 ms，每段独立使用固定 4 秒预算与最后 400 ms 清理保留。
runner 在每段后分别校验 drag 两端 routing readiness、两层 delivery receipt、focus restore 与 pointer restore，然后后台等待 debounce session、diagnostic `sidebar-frame` 和最新 resize trace segment 一致，再生成严格扁平 aggregate；最终 verifier 要求恰好两次 activation、两段均恢复成功并逐层复核两个内嵌 `resize-state`。
`--foreground-batch tab-session-lifecycle` 使用 `switch-commit`、`close-right-reopen`、`close-left-seed`、`seed-layout` 和 `relaunch-scroll-check` 五段独立前台阶段，验证标签切换提交、dirty 二次关闭、左右相邻选择、恢复关闭标签和重启后的工作区绑定。
五段的 validator 保守估算依次是 1640 ms、2690 ms、2000 ms、1660 ms 和 1880 ms，每段都有独立 4000 ms 硬上限并另保留最后 400 ms 清理时间。
前四段后，runner 通过正常 Cocoa terminate 要求 App 重建精确 session JSON，再在 passive observer 下无输入、offscreen 重启相同隔离 profile。
严格 verifier 逐项断言精确 session 与 dirty 源码、tab 顺序、非首位 active tab、字号、侧栏宽度与显隐、目录展开状态、每个 tab 的 scroll 和 fixture workspace row 到原 tab 的绑定，并拒绝重复 tab。
第五段验证恢复状态后，runner 再执行一次正常 Cocoa terminate 并再次要求精确 session flush。
`--foreground-batch save-lifecycle` 固定使用 `1180x760`，覆盖活动块、活动表格单元格、非 Markdown 原生源码、普通保存冲突、Save As 新路径与 canonical 路径检查、dirty Session 外部冲突，以及非 Markdown diagnostic 即时切换。
该 suite 的每个前台阶段继续使用固定 4 秒预算，runner 在阶段间负责外部字节替换、正常 Session 终止与恢复，并由严格 verifier 检查磁盘内容、草稿、dirty、基线、编辑器、toast、state.json 和 HUD OCR。
当前共有 `palette-find`、`find-options`、`find-regex-replace`、`preview-content`、`preview-footnotes`、`outline-navigation`、`sidebar-filter-navigation`、`sidebar-layout-controls`、`tab-session-lifecycle`、`save-lifecycle`、`table-controls`、`table-navigation`、`editor-structure` 和 `editor-boundaries` 十四个命名 bounded foreground suite。
`palette-find` 与 `sidebar-layout-controls` 各使用两段独立 foreground driver call，`tab-session-lifecycle` 使用五段，`save-lifecycle` 使用按场景隔离的多段 call，其余 suite 使用单次 call；所有单次 suite 和多段 suite 的每一段都独立受 4 秒预算约束。
这些较新批次的计划、固定预算校验和 harness 已离线通过，并有对应的模型、AX 或严格合成 fixture 覆盖；`preview-content` 还通过了不触碰通用剪贴板的 named pasteboard 多 item、多 type 与空状态原样恢复自测。
控制台锁屏状态由每次运行的 preflight 即时采样，不是持续不变的 harness 状态。
最近一次只读 preflight 报告 `sessionLocked=false`，但当前源树匹配的真实 App 动作证据仍待执行，本文不据此声称任何 foreground suite 已通过。
driver 会为每次单调用和 `tab-session-lifecycle` 的每段保留最后 400 ms，用于释放合成输入并恢复焦点和鼠标，不使用会绕过清理逻辑的进程级强杀超时。
foreground driver 正常完成时必须在返回前恢复原焦点和鼠标位置，之后只进行截图归一化、diff、OCR 和结构化状态读取。
检测到用户输入时批次立即失败，不覆盖用户刚移动到的新鼠标位置，并且只在被测 App 仍持有前台时恢复原焦点。
所有 bounded foreground batch 都额外要求 Input Monitoring 的 listen-event 权限来运行只读干扰监视器；extended full-pointer 不使用这项 monitor。
`--keyboard-only` 是会反复抢焦点的 legacy keyboard 矩阵，`--extended-full-pointer` 是还会反复移动系统鼠标的 legacy 完整矩阵，两者都只能显式选择。
`--static-only` 仅作为默认 passive tier 的废弃兼容别名保留。
根证据用 `interactionTier`、`foregroundBatchName`、`mode`、`runScope`、`strictVisualAcceptanceEligible`、动态尺寸与状态列表、`coverage`、`interactionCoverage` 和 `foregroundReport` 记录真实执行边界。
`tab-session-lifecycle` 的根 foreground 证据还聚合 `foregroundPhases`、`sessionRelaunch`，以及包围首次正常终止、无输入 offscreen 重启和第二次正常终止的 passive lifecycle assertions。
bounded foreground 证据固定把 `visualCoverageApplicable` 与 `requestedPairsComplete` 标为 false，并用独立 interaction coverage 记录计划与完成动作数、一次激活、干扰、超时和桌面恢复，避免空视觉集合被误读为完整覆盖。
更多模式、权限和证据语义见 `scripts/e2e/README.md`。

### 4. 设计稿捕获与视觉差异

```bash
./scripts/visual/capture-reference.sh
./scripts/visual/compare-real-app.sh
```

参考图写入 `build/visual-reference/`，真实应用对比默认写入 `build/visual-diff/real-app-latest/`。
更多状态、依赖和判定规则见 `scripts/visual/README.md`。

### 5. Release USER 冒烟

```bash
./scripts/release-smoke.sh
```

该脚本构建 Release 包，检查包内没有 Debug 或设计资源，以临时 bundle 身份启动隔离副本，并确认 Release 不接受视觉测试参数且首启会话为空白文档。

## 当前真实 App 状态与尺寸矩阵

最近一轮完整 passive 3x7 矩阵与严格状态和几何门禁曾通过，但后续源码变化已使其 source-tree hash 过期，最终树仍需重跑。
passive 的 Debug 状态预置用于复现可观察 UI，不等同于真实点击、键盘输入、hover 或拖拽动作。
严格视觉门禁通过只证明这 21 个稳定状态的机器断言、非文字几何和全帧像素差异符合合同，不等于完整交互 DoD 已达成。
控制台是否锁屏是每次运行的 preflight 事实，不作为持久实现状态写死。
最近一次只读 preflight 报告 `sessionLocked=false`，但该读取不启动 App，也不是 foreground suite 的动作通过证据。
旧的单段 `palette-find` 曾在 4 秒预算内通过，但该证据不仅因源码变化而过期，也不再匹配当前两段式计划。
新的 `block-find` 与 `palette-keyboard` 需要在最终树上分别运行并生成聚合证据。
旧的 `table-controls` 证据曾在 `sessionLocked=true` 的 preflight 安全阻塞，该历史结果不代表当前控制台状态，也不构成动作通过证据。
`editor-structure`、`editor-boundaries`、`table-navigation`、`find-options`、`find-regex-replace`、`preview-content`、`preview-footnotes`、`outline-navigation`、`sidebar-filter-navigation` 和 `sidebar-layout-controls` 的离线计划、固定预算校验与 harness 已通过，并有对应的模型、AX 或严格合成 fixture 覆盖。
`tab-session-lifecycle` 已具有五段预算、正常终止、无输入 offscreen 重启、严格 session verifier 和根证据聚合合同，但同样不能替代当前源树真实 App 运行。
`save-lifecycle` 的离线计划、预算、harness 和严格 verifier 已通过；当前树的 bounded run 在首动作前被输入干扰守卫终止，Goal 2 改由同一 `1180x760` Debug App 可见操作完成真实验收，不能把这组手工证据表述成 bounded suite 自动通过。
当前十四个 foreground suite 仍需各自生成与最终当前源树匹配的自动动作证据。
只有 source-tree hash 与当前 worktree 匹配的 `evidence.json` 才能作为当前结论。

| 真实 App 场景 | 默认 passive 三尺寸 | bounded foreground `1180x760` | 显式 legacy tier | 当前证据状态 |
|---|---|---|---|---|
| fixture 基线、窗口、侧栏 fixture 行、active 行、active tab | 真实 App 截图、Vision OCR、诊断和 lifecycle 全部覆盖 | 批次前也会捕获 | 也保留 | 历史最近一次 passive 通过，最终 source tree 待重跑 |
| palette、Find、纯预览与预览 toast、侧栏隐藏 | 每个状态独立 profile 与 PID，三个尺寸均捕获并通过严格几何 | `palette-find` 覆盖 Find 和 palette；`preview-content` 与 `preview-footnotes` 规划快捷键进入预览、内容交互和返回编辑 | keyboard 与 extended 保留动作路径 | 历史视觉状态通过；两个预览交互批次仅离线验证通过，当前源树匹配的真实动作仍待运行 |
| 单块源码编辑器 | 三尺寸捕获首块源码、source selection、可见性和几何 | `palette-find` 点击首块、输入并提交 | extended 在 `1180x760` 还有旧流程 | bounded 成功证据需在最终 source tree 重跑 |
| 表格网格 | 三尺寸捕获首表头焦点、确定性滚动、177 pt 网格和可见性 | `table-controls` 规划输入与工具栏操作；`table-navigation` 规划 Tab、Shift+Tab、Return、末格自动增行、精确焦点序列和 Esc | extended 保留旧的单元格流程 | 两个短批次都需在当前源树上运行；`table-navigation` 目前仅离线计划、harness 和单元用例通过 |
| 大纲静止态 | 三尺寸捕获并验证几何 | `outline-navigation` 规划精确 AX hover、物理点击、跳转中、wash 峰值、渐隐和清除 | extended 保留三尺寸 hover | 历史静止态通过但最终树待重跑；新批次的 plan、harness 和策略测试离线通过，当前源树匹配的真实动作仍待运行 |
| Find 全词点击、输入、替换和导航 | 只捕获空 query 面板 | `palette-find` 规划导航；`find-options` 规划大小写与全词；`find-regex-replace` 规划捕获组单次替换和剩余项全部替换 | extended 覆盖完整 find-and-replace 路径 | 两个新 Find 短批次目前仅离线计划、harness 和单元用例通过，当前源树匹配的真实动作仍待运行 |
| 结构化块编辑命令与提交 | 三尺寸只捕获确定性源码编辑器 | `editor-structure` 规划引用与列表命令；`editor-boundaries` 规划上下边界移动、斜体、行内代码、块首 Backspace 合并和 Esc | extended 保留旧的单块输入流程 | `editor-boundaries` 目前仅离线计划、harness 和单元用例通过，当前源树匹配的真实动作仍待运行 |
| 标签关闭与恢复、块和表格提交、session 源码断言 | 不执行动作 | `tab-session-lifecycle` 用五段独立 4 秒前台阶段覆盖标签切换提交、dirty 二次关闭、左右相邻选择、恢复关闭标签、正常终止、无输入 offscreen 重启、恢复后 workspace row 绑定和第二次正常终止；编辑器与表格 suite 规划各自提交 | keyboard 或 extended 保留部分流程 | tab 和 relaunch 已有短 suite、严格 verifier 与根 passive lifecycle 聚合，但当前源树匹配的自动真实 App 动作仍待运行 |
| 保存生命周期、外部冲突和非 Markdown diagnostic | 不执行动作 | `save-lifecycle` 规划活动块、活动表格、纯源码、Cmd+S、菜单保存、外部修改、Save As 新路径、canonical 与 symlink、dirty Session 和即时 diagnostic | 无需 legacy tier | 离线 plan、harness、严格 verifier 和原生编辑器回归通过；当前树已在隔离 `1180x760` Debug App 可见验收，bounded driver 因首动作前输入干扰而未产生自动通过证据 |
| 侧栏过滤与 resize、系统面板和 drag/drop | 不覆盖动作 | `sidebar-filter-navigation` 规划名称与相对路径过滤、空结果、键盘打开与清空；`sidebar-layout-controls` 规划文件夹折叠展开、176/440 pt resize clamp 和隐藏恢复；`tab-session-lifecycle` 规划重启后侧栏与 workspace 绑定恢复 | legacy 仍保留较弱的侧栏开关路径 | 短 suite 的 plan、预算、harness、严格 session、diagnostic 和 AX verifier 离线覆盖已建立；当前源树匹配的真实动作仍待运行，系统 drag/drop 仍无覆盖 |
| 代码复制、任务点击、链接与脚注 hover 或跳转、tooltip 和 drag overlay | 不覆盖动作 | `preview-content` 规划预览内任务点击、Bash 卡片 hover、复制点击、精确剪贴板校验与恢复；`preview-footnotes` 规划脚注引用 hover、物理点击、定义跳转和返回 | 当前 runner 未完整覆盖 | 两个预览批次的离线 plan 与 harness 通过，AX 和相关模型单元覆盖通过；当前源树匹配的真实动作仍待运行，普通外链、tooltip 和 drag overlay 仍无覆盖 |

## 视觉证据语义与验收门槛

参考捕获器校验权威 HTML 的 SHA-256、`ui/support.js` 中的 React URL 与 SRI pins、缓存或下载后的 runtime bytes，并使用非持久 WebKit data store。
WebKit 只存在于独立参考工具中，不进入产品 target。

默认参考捕获和默认 real-app compare 都请求七个映射状态的三个尺寸，共二十一个 pair。
默认 passive E2E 使用确定性状态入口生成相同的七状态三尺寸矩阵，并为每个 pair 记录独立 PID、profile、offscreen window identity、lifecycle 和 screenshot-bound visual evidence。
只有未过滤的完整 passive 矩阵能产生这二十一个严格视觉 pair；任何显式 probe filter 生成的笛卡尔积都保持 strict-ineligible。
compare 会检查两个 manifest、权威哈希、验收合同哈希、完整 coverage、每个请求 pair 的记录与文件路径、像素尺寸、状态断言、几何锚点和严格像素合同。
任何 pair 缺失、状态不符、锚点缺失、证据 blocked 或 probe 不具备严格资格时都会失败。
映射是 `default`、`palette`、`find`、`preview`、`sidebar-hidden`、`source-editor` 和 `table-editor`，而 reference-only 的 `replace` 没有真实 App 映射。

`scripts/visual/compose-diff.py` 把任一 RGB channel 差值大于固定 threshold 8 的像素计为 changed pixel。
输出包括 exact changed ratio、thresholded changed ratio、mean absolute channel difference、RMS、PSNR、最大 channel 差值、连通区域、横纵连续长度、局部 tile 密度、50 percent overlay 和 heatmap。
`scripts/visual/compare-real-app.sh` 拒绝任何非 8 的 threshold，不能通过命令行放宽合同。
评估器直接从截图哈希绑定的两张 PNG 重算完整像素分析，并拒绝被修改或伪造的 metrics JSON。
`scripts/visual/compare-real-app.sh` 自动计算每个 required geometry anchor 的最大分量误差，并把根验收状态写为 `passed` 或 `failed`。
`1180x760` 的每个非文字矩形分量容差为 1 px，其他验证尺寸为 2 px，边界值包含在允许范围内。
缺失矩形、非法数字、重复或未评估锚点、未允许的 probe source 和缺失状态断言都会失败。

验收同时要求 changed-pixel ratio、结构差异比例、高幅差异比例、MAE、RMS、最大连通区域、长直线和局部 tile 密度全部不超过合同上限，不能用一个较好的总像素比例抵消成片背景、边框、图标或布局差异。
当前合同的 changed-pixel ratio 上限为 1.5%，结构差异与高幅差异比例上限均为 0.01%，其余固定空间上限见 `scripts/visual/README.md`。
当前工具不使用 mask 或 ignored region。
只有两张图在同一像素附近都存在亮度边缘且最大 channel 差值不超过 48 时，该像素才会被标记为抗锯齿候选，但它仍计入 changed aggregate、连通区域、长直线和 tile 密度。
因此视觉复核仍应同时检查 App 图、参考图、overlay、heatmap、metrics 和非文字几何锚点，不只看单一像素比率。

## 依赖

- Swift 构建、Debug App、E2E driver 和 WebKit reference runner 需要 Xcode Command Line Tools 或完整 Xcode。
- E2E evidence JSON、Release smoke 和视觉脚本需要 Python 3。
- `scripts/visual/compose-diff.py` 和 `Tests/Visual/VisualToolTests.sh` 需要 Pillow，可用 `python3 -m pip install Pillow` 安装。
- `Tests/E2E/RealAppHarnessTests.sh`、`Tests/E2E/BuildDebugIncrementalTests.sh`、`Tests/E2E/RunDebugLaunchIdentityTests.sh` 和 `Tests/Visual/VisualToolTests.sh` 需要 `rg`；实际 real-app E2E runner 与视觉 compare 不依赖 `rg`。
- 每次 reference capture 都需要 `openssl` 校验 SRI，只有本地 pinned runtime cache 缺失或无效时才需要网络和 `curl`。

## 证据判定规则

- 不把仓库中某次历史运行的测试数量或提交号当作当前结论。
- 单元测试结论以 `./scripts/test.sh` 的当前退出状态为准。
- E2E 结论以当前运行生成的 `evidence.json`、各尺寸 `manifest.json`、截图和直接 session assertion 为准。
- E2E 内部 before-and-after `changedPixelRatio` 只是状态变化下限保护，不是设计稿对比。
- 视觉结论需要同时检查数值指标、overlay、heatmap、真实截图和非文字几何锚点，不只看单一像素比率。
- Release 隔离结论以 `./scripts/release-smoke.sh` 的当前退出状态为准。
- 任何没有直接证据、只有间接证据或验证范围更窄的要求都保持 `uncovered`，不能从实现意图外推为已通过。
- 任何可见偏差都应先复现在真实 `.app` 中，再修改实现；不得修改权威设计终稿来迁就 App。
