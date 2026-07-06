# UI 规约对齐 — 跟踪表

> 设计真相源：`ui/Markdown Viewer.dc.html`
> 主分支：`main` @ `d6f2128`（含 P0 · P1 11 项 · 会话持久化#29 · 打字性能 · 查找批 A）　当前发布 **v1.0.6**（版本从仓库根 `VERSION` 单一来源，`scripts/build.sh` 注入；SHA 做 build 号）　批次约定：`p0` / `p1` / … 各自命名
> 最近更新：2026-06-30

质检共 30 条，已逐条对源核验。状态分：✅完成 / 🔧进行中 / ⏳待办 / ❓待拍板 / ⛔不做(已拍板)。

---

## 分支约定

- 每个批次单独成支：`p0` / `p1` / … 各自命名，验收后 fast-forward 合 `main`。
- `wave3-C`（前序对齐 + 打磨 WIP，止于 `c51a901`）与 `p0`（P0 批次 8 提交）均已合入 **`main`**（顶 `bb13201`）。
- `p0` 分支保留作批次记录；下一批次从 `main` 新拉。

## P0 — 行为正确性 / 首屏观感（✅ 已完成并合入 main，用户已验收）

分支 `p0` @ `bb13201`，已 fast-forward 合入 `main`。功能 + #18 滚动顺滑度均经用户确认。

| # | 问题 | 工作量 | 执行单元 | 状态 |
|---|---|---|---|---|
| 9 | ⌘F 重复按会关掉查找；应永远 open+focus+select+recompute | S | Exec1 查找&面板 | ✅ |
| 10 | 关闭查找未清 query/count/error/replace/高亮 | S | Exec1 查找&面板 | ✅ |
| 14 | 命令面板"查找/替换"会把已开查找关掉；应 openFind | S | Exec1 查找&面板 | ✅ |
| 15 | 命令面板看不到打开的 tab/未命名文档（最小版：union tabs） | S→M | Exec1 查找&面板 | ✅（完整 buildDefs 对齐留待数据流波次，已留 TODO 标记） |
| 5 | 侧栏筛选无键盘导航/高亮/Enter 打开 | M | Exec2 侧栏 | ✅ |
| 18 | 滚动时右侧目录当前项不更新（只更新进度条） | S | Exec3 目录 | ✅ |
| 18-perf | 滚动同步卡顿 | S | Exec 性能 | ✅ 两层修复：① 计算——缓存标题偏移+二分查找（`OutlineController.swift`，`60a01c4`）；② 渲染——`activeHeadingIndex` 拆成独立 `ActiveHeadingModel`（`@State` 持有、仅目录条观察），滚动跨标题只重渲目录条不重渲整个 ContentView（`bb13201`）。待用户验证 |

> 注：`hoveredURL` 等同源「整树重渲」问题已作为性能项并入下方 P1/P2 优先级（见 性能-1..5）。

冲突域：Exec1=FindState/FindBarView/CommandPalette/DocumentManager/ContentView；Exec2=SidebarView；Exec3=EditorView。三者文件互不重叠，独立 worktree 开发，owner 统一核验合并。

### P0 引入的技术债（需后续清理）
- **`FindState.toggleOpen()` 已成误名**：⌘F 菜单绑定在 `App.swift`（不在 Exec1 文件范围内），为实现 #9「永远 open」，Exec1 把 `toggleOpen()` 改成调用 `openFind()`（不再 toggle）。行为正确，但命名误导。**后续应**：把 `App.swift` 的 ⌘F 绑定直接指向 `openFind()`，删除 `toggleOpen()`。归入"查找&面板补全波次"。

---

## p1 — P1 档批次（✅ 完成，待用户验收）

分支 `p1` @ `7f42ae6`（从 main，4 个并行 worktree 合并），集成构建 + 打包通过。含 11 项；延后的 {#29, 性能-1} 不在内。

| 项 | 内容 | 波 |
|---|---|---|
| #22 | 非 Markdown 文件源码视图 + `非 Markdown 文件 · 以源码形式查看` banner（`DocumentTab.isMarkdown`） | W1 |
| #1/#2 | 首启 / 新建空白 untitled，不塞 demo | W1 |
| #26 | 状态栏字体改 tabular-digit（去 monospaced 家族） | W1 |
| #27 | 底部 padding 响应式 33vh（`ResponsiveScrollView.tile` 动态 contentInset） | W1 |
| #28 | 拖拽仅 .md/.markdown/.txt，不支持 toast | W1 |
| 性能-2 | hoveredURL 隔离到 `HoverURLModel`，hover 不再整树重渲 | W1 |
| #11 | 查找 Shift+Enter 上一个 / Esc 关闭（含替换框，NSEvent 监听） | W2 |
| #12 | 查找面板白 .97+blur、输入底 .045（本地，不动 DesignTokens） | W2 |
| #17 | 命令面板行单行 ellipsis | W2 |
| #6 | 侧栏筛选递归 flatten 匹配嵌套文件 | W3 |
| #21 | 目录跳转 300ms 滚动 + 900ms wash（滚动结束后触发） | W4 |

合入 `main`：待用户验收后进行。

### p1 验证轮发现并修复（@ `900c63b`）
- **日志**：`MVLog` 内存环形缓冲 200 条，崩溃（NSException + 6 信号）flush 到 `~/Library/Logs/MarkdownViewer/crash/`。搜索/缩放路径已加日志点。
- **崩溃**：不盲修——靠日志抓真实堆栈。疑因（诊断）：find 匹配范围在文档长度变化后被使用 → 越界；#27 `tile()` 重入为协同因素。已加范围越界保护 + 修了 tile 重入，若仍复现等 crash log。
- **#27 滚动漂移**：inset 计算移出 `tile()`，缩放时保存/恢复滚动位置。
- **inline 代码不高亮**：绘制顺序——填完代码底色后补描 find/目录临时高亮。
- **搜索闪白/卡顿**：debounce 120ms + 只清上次匹配范围（不再全文清/重扫）+ 范围越界保护。
- 性能-4（查找输入整树重渲）：用户确认**不提前**，留原 todo。
- **非 md 打开卡死**（打开 .toml 无响应）：根因——大纲未按 `isMarkdown` 关闭，TOML/YAML 的 `#` 注释被当成几百个 H1 标题 + 每个做布局查询。修复：非 md 文件四个出口（打开/文本变更/滚动/ContentView 渲染）全部不构建/不渲染大纲（`cac718a`）。这是 #22 的遗漏（当时只 gate 了样式器）。
- **非 md 扫描同类隐患**：`refreshTextCaches()` 也按 `isMarkdown` gate 了——非 md 跳过 `fencedCodeBlocks/linkRanges` 全文扫描并清空缓存（`6537d78`）。
- **#27 收缩漂移**：根因——`frameDidChange` 在 AppKit 已移动 `bounds.origin.y` 之后才触发，捕获的是漂移后的值。修法：`viewWillStartLiveResize` 拖拽前快照锚点、`viewDidEndLiveResize` 重钉（`13df4c8`）。
- **删除闪白**：根因——`clearHighlights` 调 `removeTemporaryAttribute` 没配 `invalidateDisplay`，清除被推迟后一次性重绘全部旧高亮。修法：每次 remove 配 `invalidateDisplay`（`13df4c8`）。

> p1 当前顶 `d74aede`（含上述全部修复 + 日志），合 main 待用户验收。

### 闪白（✅ 真因确认 = 编辑正文时整篇重排，非查找）
- 用户确认"整篇样式消失一帧" → 是 `LiveMarkdownStyler.apply` 对**整篇** textStorage 重着色+重排，**只在正文编辑（`textDidChange`，`EditorView.swift:271`，每键全文重排）时触发**，与查找高亮无关。正文打字/删除都闪，删除更明显；查找框本身不触发。
- 教训：前两次（invalidateDisplay、视口化高亮）都盯着 find 改，方向错，视口化还引入"打字也闪"的回归已 `reset` 回退到 `d74aede`。
- 修法：**增量重排**（✅ 已修，`f9ba385`，待用户验）——`applyIncremental` 只重排被编辑块（按 fenced 容器/段落+空行边界扩展），结构性编辑（围栏```/空行增删/表格`|`/HR、贴近围栏、无 editedRange）**回退全篇**。编辑范围经 `NSTextStorageDelegate.didProcessEditing` 捕获。load/font/replace 仍走全篇 `apply`。
- **验证亮点**：执行者用属性逐字符 diff harness 证明 `applyIncremental` 输出与全篇 `apply` **逐字节一致**（覆盖纯编辑/标题↔正文/取消加粗/围栏内/列表/引用/行内码/空行合并/贴近围栏），即无陈旧/错误样式。仅合成验证，未跑 GUI。
- layer-backed（#4）未用，增量重排已治本。

### 查找只匹配正文「所见即所搜」（✅ 完成，用户逐版真机验，末版「没问题了」· v1.0.1→v1.0.6）
- **边界拍板（用户 2026-07-03）= 所见即所搜**：查找只命中屏幕上可见的正文；隐藏语法符号、链接 URL、图片路径、列表符号、代码语言标签均不参与匹配。**行内代码/代码块内容可搜**（它们可见），仅围栏/反引号/语言标签排除。
- **实现**：styler 给非正文区间盖可查询属性 `.mvNonBody`（单一事实来源，随全量 `apply` / 增量 `applyIncremental` 的 `setAttributes` 重置天然同步）；`FindController.BodyMap` 据此 **+ 兜底排除不可见字形**（字号≤1.5 或前景近透明——任何隐藏机制都盖住，不依赖每个隐藏点都记得盖标记）拼出"正文串"、建正文↔原文 range 映射，在正文串上跑现有正则（含区分大小写/全词/正则+非法正则报错）再映射回原文做高亮/跳转/替换。
- **一路修复链（每步真机验）**：v1.0.1 body-only 映射（`d492785`）→ v1.0.2 代码块**内容**恢复可搜（初版误把整块排除）→ v1.0.4 **加粗渲染 bug**（强调 `**`/`__`/`*`/`~~` 解析无视代码边界：`*` 在 `` `reader__*` `` 里破坏整行 `**` 配对→漏成可见字面量；`__` 在 `mcp__reader__x` 里被误加粗。修：强调匹配前把行内代码+代码块区遮罩成空格，长度不变、位置对齐）→ v1.0.5 查找高亮调深（`accentStrong` 0.55→0.85 / `accentSoft` 0.22→0.34，灰代码卡片上也看得清；当前项醒目即"跳到这了"的信号）→ v1.0.6 **滚动定位 bug**（`NSTextView.scrollRangeToVisible` 在自定义 `ResponsiveScrollView` 里对文档深处匹配失效→页面不滚；修：改用会话恢复同款 clip-view 直接滚 + 相同 maxY 钳制 + **居中**匹配）。
- **调试工具（用户要求，保留）**：`--debug` HUD 移到**左下、可折叠**（× 收起 / ▸DIAG 展开）；新增 find 诊断读数 = `shown/raw/filtered` + **独立**健康计数 `zeroRect`（布局引擎实测渲染高度，真·可见性，不复用排除规则）/`inCode` + 逐条明细（offset/code/size/fgA/rectH/上下文）+ `SCROLL` 数值（target/before/after/viewport）；**点击 HUD 复制整份诊断**（免截图）。全部 gated 于 `AppEnv.debug`，USER 模式不显示。
- 验证：真 `LiveMarkdownStyler`+`FindController` harness 16/16 用例（含加粗×行内代码交叉、代码块内容、code-then-body 双命中）；真机 E2E 用户逐版确认。
- **教训**：中途"零宽隐身字符"的判断被 debug 的独立 `zeroRect`（rectH≈27，全可见）推翻——真因是加粗渲染漏 `**` + 滚动失效 + 高亮太淡，不是隐身。**独立于修复规则的诊断指标**是关键（用户点破了自证式的旧 `leak` 校验）。

### 架构演进候选（后续可选，不进当前批）
- **⭐ 块级模型（block-based）— 用户 2026-07-03 拍板为「长期必做」，记为 TODO**：文档=独立块列表，改一块只重渲一块，计算+布局与文档大小解耦（Notion / Craft / Bear 2 方向）。是"大文档布局"的终极解，等价重写编辑器内核 + 文档模型。**后续单独立项**，不在当前性能收尾内。
- **TextKit 2 迁移**（`NSTextLayoutManager` + viewport 渲染）：把"只渲染可视区"内建进底层，根治整篇布局/重绘类问题。成本=项目级重写（`CardLayoutManager` 等自绘逻辑全部重做）。**不为单个 bug 立项。**
- **业界现状结论（2026-07-03 联网调研，详见 artifact 对照文档）**：想要大文档规模的原生编辑器都**绕开 TextKit 2**（实测对编辑型 UI 不成熟——STTextView/ChimeHQ/CodeEdit 均弃用）。终极解走「自研 CoreText 视口引擎」(CodeEdit) 或「块级模型 / 重写解析器」(Notion / Bear 2)，**不是 TextKit 2**。
- **触发线（撞够再提迁移）**：① 反复出现整篇重绘/重排类闪烁卡顿；② 大文档（MB 级）整体卡（TextKit 1 全量排版固有）；③ 绕 `NSLayoutManager` 子类的 hack 持续增多。

---

## 已拍板的决策

| # | 问题 | 决策 |
|---|---|---|
| 4 | 侧栏文件夹默认应展开（设计） | ⛔ **不改**，保留现状（默认折叠），用户认为现状更好。有意偏离规约。 |
| 2 | 新建文档：空白 vs 预填 | ✅ **空白**。新建 / 首启 untitled 均为空文档。 |
| 1 | 首屏种子 demo 文件 | ✅ **不塞**。设计稿的 SKILL.md/agents/… 仅示意（与 #3 同类）；首启开空白 untitled，侧栏靠打开文件夹填充。 |
| 29 + 性能-1 | 会话持久化 / 打字整树重构（=「B 文本模型统一」） | **性能-1 打字隔离 ✅**(`a524823`,用户已验) · **会话持久化 #29 ✅**(并入 `303edf4` 前,用户验"没大问题":tabs含未存/active/字号/侧栏宽/每tab滚动/文件夹 → 会话文件) · **Phase3 编辑器复用·保留切tab撤销 ⏳**降级最后,未开工。<br>**打字性能收尾(新线程)**:实测每键重排过多 `inc:9 full:75` → **②节流/合并渲染 ✅**(每帧≤1次重排,`0f9efa9`,用户已验"没问题":`full` 仍高但连打已顺——频率封顶即治本) · **①局部增量去全文扫描 ⏳**(用户 07-03 定"先不做";当前文档体量下不需要,留大文档再上) · `303edf4` 已修 `requiresFullRestyle` 空行邻近误触发。业界 6 类方案对照见 artifact。 |
| 23/24 | H2 / 代码语言标签 uppercase | ✅ **保持原状**（不转大写，实时编辑器不篡改源文本）。 |
| 3 | 自绘红绿灯 | ⛔ **不做**，保留系统原生红绿灯。 |
| 16 | 命令面板蒙层 0.4 vs 设计 0.6 | ✅ **改，对齐设计稿 0.6**（配套调毛玻璃材质，使 0.6 观感符合设计、非近乎不透明）。归样式波次。 |
| 19 | 目录 hover 优先级 | ✅ **不改**，当前项始终**琥珀**（用户偏好，有意偏离设计稿 hover 胜出）。 |

> **用户原则（默认）**：所有 UI 类变更都需**对齐设计稿**（#3/#16 均按此定）；个别项经用户明确拍板可偏离（如 #4 折叠、#19 琥珀）。样式/打磨波次一律以设计稿数值为准。

---

## P1 — 明确保真差距（✅ 已对账 2026-07-06，逐项到代码核实）

**✅ 已完成**（对账时逐一验过代码位置）：
- **#22** 非 md 走源码视图（`EditorView.isMarkdown` gate）· **#29** 会话持久化（本会话 B，`SessionStore`）· **#11** 查找 Shift+Enter/Esc（`FindBarView:11`）· **#12** 查找面板 白.97+blur（`FindBarView:211`）· **#17** 面板行 `lineLimit(1)`+truncation（`CommandPalette:287`）· **#26** 状态栏 `.monospacedDigit()` tabular 非 monospaced（`ContentView:323`）· **#21** 目录跳转 0.3s ease 滚动 + 0.9s amber wash（`OutlineController.jumpTo`/`washHeading`）· **#27** 底部 33vh 响应式（`ResponsiveScrollView`）· **#28** 拖入只 `.md/.markdown/.txt` + toast「仅支持 Markdown / 文本文件」（`ContentView.handleDrop`）· **性能-1** 打字隔离（本会话，`a524823`）· **性能-2** `HoverURLModel` 隔离
- **#1** 首屏种子 → ⛔ 已决策为**不塞**（空白首启，见下「已拍板 #1/#2」），非待办

**⬜ 仍待办**：

| # | 问题 | 工作量 | 修复方式 |
|---|---|---|---|
| 6 | 侧栏筛选命中行**不显示相对路径**（`SidebarNodeRow` depth:0 只显文件名，同名不同目录无法区分）。〔更正:递归搜嵌套**已做** —— `SidebarView.filteredNodes` 用 `flattenFiles`;之前对账误看已删的死属性 `visibleFiles`〕 | S | 筛选时名称旁显示相对路径（由 `FileNode.url` 相对 `directoryURL` 算）。用户 2026-07-06 定:拍平单列 + 相对路径（拍平已具备） |
| 15 | 命令面板完整 tab/文档视图 parity（最小 union 已做） | S→M | 完整 `buildDefs` 对齐，随「数据流波次」 |

---

## P2 — 打磨 / 低影响（= 批 C，已对账 2026-07-06）

**✅ v1.0.7 已交（UI 打磨 5 项，`de808a6`）**：**#7** resize 三态蓝线（拖=rgba(10,132,255,.6)）· **#25** 复制按钮 hover 变深（`contentTintColor`）· **#13** 查找芯片 OFF 态 hover 底 · **#8** 删 tab 条多余 8px padding · **#20** coach key 统一常量 + 删死变量 `pulse`

**⬜ 仍待办（C 剩余 = perf 隔离，下一步）**：

| # | 问题 | 工作量 | 修复方式 |
|---|---|---|---|
| 性能-3 | `EditorBridge.charCount/lineCount` → 编辑整树重渲（仅状态栏用） | S | 挪到独立指标模型，仅 `EditorStatusBar` 观察 |
| 性能-5 | `DocumentManager.sideFilter` → 侧栏筛选每键整树重渲（CV 没读它） | S | 挪到 `@State` 模型，仅 `SidebarView` 观察 |
| 性能-4 | `FindState.query/replaceText` → 查找每键整树重渲 | M | ⏸ 用户 2026-07-03 定「**不提前**」，按住；将来拆 `FindFieldModel` 仅 `FindBarView` 观察 |

---

## ❓ 待拍板（✅ 已清零 2026-07-06 — 全部方向已定）

- **#23/24、#3、#16、#19** — 见上方「已拍板的决策」（用户重申:已定的别再问，见 [[dont-reask-decided]]）。
- **#30 tooltip 全局 mousedown 隐藏 → 用户定「搁置」**。现有行为「鼠标移开即隐」（`MVTooltip` `.onHover` 退出 → `cancelAndHide`）已够用；未覆盖的仅「悬停中直接点击目标」这一窄场景（规约要 mousedown 即隐），收益低。记 TODO，不做。

---

## 剩余路线（✅ 已对账 2026-07-06，仅列真正未做的）

> 计划序 **BACDEF**：B（文本模型+打字性能）✅ 除 Phase3 · A（查找）✅ v1.0.6 · C（打磨）进行中。

1. **C 剩余 · perf 隔离**（下一步，同款 @Published 拆隔离手法）：性能-3 字数 · 性能-5 侧栏筛选。（性能-4 用户「不提前」按住。）
2. **D · 技术债**：`toggleOpen` 清理（`App.swift` ⌘F 直指 `openFind()` 后删）· 正则替换 `$1` 反向引用 + 「没有可替换的匹配」空态 toast · 非 md 源码视图的卡片/复制 chrome 收敛。
3. **保真补全**：#6 侧栏嵌套递归筛选 · #15 命令面板完整 tab/文档 parity。
4. **E · 待拍板落地**（见上「待拍板」表）：#16 蒙层 0.6 + 材质 · #30 tooltip（建议搁置）· #23/24 大写 · #19 目录 hover · #3 红绿灯（建议不做）。
5. **降级 / 长期**：B Phase 3 编辑器复用（切 tab 保留每 tab 撤销历史）· ⑤ 块级模型（大文档终极解，单独立项）。

> 低风险性能项（性能-2/3/4/5）彼此独立、不依赖 #2，需要的话可从所属波次拆出提前做。
