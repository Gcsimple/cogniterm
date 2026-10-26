# 下一步特性：从「操作」角度

> 起因（2026-10-26）：MVP 已发布 v0.1.0。下一轮不追功能广度，只解决**操作摩擦**。
> 本文先按「一次任务的真实操作链路」盘点现状（全部带代码引用），再定位断流点，
> 最后给候选特性 + 需要拍板的决策点。
>
> 与 `terminal-interaction-upgrade.md` 的分工：那份管**终端本身该有的能力**
> （P0 四项 + 多标签已落地，字体/OSC 133/QuickSelect/命令面板仍未做）；
> 这份管**终端与对话之间的操作流**——即本产品独有的「agent 和 shell 同一平面」这条主线。

---

## 一、结论先说

MVP 的功能是齐的，但**三个动作还是「两段式」**：

1. **看到命令 → 跑它**：agent 给的命令是纯文本，要手动拖选、复制、点终端、粘贴、回车。
2. **切终端 → 切会话**：标签栏和侧栏会话列表**都只有点击**，一个快捷键都没有。
3. **想给上下文 → 给不进去**：输入框固定 64pt，拖文件、粘图、调历史全都没有。

这三处都发生在**每次任务都会经过的路径**上，不是边角功能。补完它们，
「agent + terminal 共用一个执行平面」这个卖点才在手上兑现。

---

## 二、现状盘点：五条主链路，各自几步

### 链路 1｜agent 建议一条命令 → 在终端执行

| 环节 | 现状 | 证据 |
|---|---|---|
| 渲染 | 助手消息是**纯文本**，markdown 原样显示（`` ``` `` 也在屏幕上） | `Views/TrajectoryView.swift:69` `bubble(Text(row.text).font(.body), …)` |
| 复制 | 只能鼠标拖选 + ⌘C（`Text` 未开 `.textSelection`，长输出里拖选容易多选） | 同上 |
| 执行 | 点终端 → ⌘V → ↵ | 无任何快捷路径 |
| 反向 | **有**：终端选区 ⌘I 发给 agent；审批卡「在终端运行」也能把 agent 的命令注入 PTY | `CogniTermApp.swift:77`、`MainSplitView.swift:166` |

**当前 5 步，且第 3 步有安全风险**：用户从对话里复制到终端执行的命令，
**不经过审批门**、不进 `PolicyEngine` 评级、也不回喂输出给 agent。
而 agent 自己调 `run_in_terminal` 时反而要过四道关。这是「同一个动作，两条路径，安全等级相反」。

### 链路 2｜切换终端会话（本地 + N 条 SSH）

| 环节 | 现状 | 证据 |
|---|---|---|
| 切标签 | 只能点（`onTapGesture`） | `Views/TerminalTabBar.swift:155`，全文件零 `keyboardShortcut` |
| 折叠态切会话 | 只能点菜单 | `MainSplitView.swift:267` 的 Menu |
| 键盘层 | 「终端」菜单 13 项里**没有一项**与标签/会话相关 | `CogniTermApp.swift:67-114` |
| 侧栏切会话 | 只能点行 | `SidebarView.swift` 零 `keyboardShortcut`（仅两处 `.cancelAction`） |

### 链路 3｜把上下文喂给 agent

| 上下文形态 | 现状 |
|---|---|
| 终端选区 | ✅ ⌘I（带 chip 显示行数，见 `ComposerView.swift:15-35`） |
| 当前屏幕 | ✅ ⇧⌘I |
| **截图 / 图片** | ❌ 无粘贴入口（`grep -rn "NSPasteboard" App/Sources` 零命中） |
| **文件 / 目录** | ❌ 无拖放（`grep -rn "onDrop\|registerForDraggedTypes" App/Sources` 零命中） |
| **对话里上一段回答** | ❌ 只有终端能 quote，对话区自己的文本不能 quote |
| 长 prompt | 固定 64pt 高（`ComposerView.swift:49`），多行要内部滚动，看不到全貌 |
| 输入历史 | ❌ 无（↑ 键在 TextEditor 里就是光标上移） |

### 链路 4｜审批

- 已有：⌘R 允许 / ⌘T 在终端运行 / ⌘. 拒绝（`ApprovalCardView.swift:80-90`）、规则记住（`onRemember`）。
- 缺：**拒绝时说不清理由**。用户拒绝后 agent 只能瞎猜，往往原样再问一遍。
- 状态是单值（`ConversationModel.swift:30` `pendingPermission`）——ACP 权限请求本身串行，单值是对的；
  但 MCP 的 `run_in_terminal` 与 ACP 权限是**两条通道**，会同时挂两张卡，界面上没有「共 N 个待处理」的总量感。

### 链路 5｜回看历史会话

- 侧栏露 5 条 → 全量 sheet（可搜索）→ 选中先看轨迹 → 再决定是否继续。
- 缺：从当前会话**一键回到上一个会话**，每次都要开 sheet。

---

## 三、三个断流点（根因）

```
① 看 → 跑      agent 输出(Text) ──✂── 终端(PTY)          缺"执行"这一跳
② 切 → 切      标签 / 会话 ──✂── 键盘                   缺快捷键层
③ 想 → 给      Composer(64pt TextEditor) ──✂── 剪贴板/文件/历史   缺捕获入口
```

三条都不是"再加个按钮"，而是**缺一层抽象**：

- ① 缺的是「**回复里的文本是结构化对象**」（代码块、行内命令、文件路径），
  现在是不可分割的字符串，所以没法在它上面挂动作。
- ② 缺的是「**标签 = ⌘数字**」这条系统级约定，标签只是 `ForEach` 出来的视图。
- ③ 缺的是「**Composer 是一个能收东西的地方**」（拖放目标 + 剪贴板嗅探 + 历史栈）。

---

## 四、候选特性

### F1｜把回复变成可操作的块（**建议最先做**）

**做什么**
1. 助手消息做**轻量 Markdown 渲染**：fenced code block、行内 `code`、无序/有序列表、粗体、链接。
2. 每个 code block 右上角三个动作：**复制** / **插入终端（不回车）** / **运行**。
3. 行内出现的**文件路径**（`App/Sources/Views/*.swift` 这类）自动变成可点 chip → 在 Finder 里显示 / 发给 agent。
4. 「运行」**必须复用审批门**：走 `conversation.respondRunInTerminal()` →
   `sessions.runCommandCaptured()`（`MainSplitView.swift:160-169` 已有这条路径），
   危险命令照样过 `PolicyEngine`，输出照样回喂 agent。

**为什么先做**
它把链路 1 从 5 步压到 1 步，并且**顺手把绕开审批的那个口子堵上**——
用户在对话里点「运行」和 agent 自己调 `run_in_terminal` 从此走同一条受审路径。

**成本 / 风险**
- 工作量 M。风险集中在一处：Markdown 解析器是自研还是引依赖（见决策点 1）。
- 视觉风险：对话区现在是「用户右气泡 / 助手左气泡」的极简风格，
  上 Markdown 后可能显得杂乱，需要先定一条：**只给代码块加装饰，正文保持裸文本排版**。

### F2｜标签与会话的键盘层（**成本最低，立刻见效**）

**做什么**
- ⌘1…⌘9 直选标签；⌃Tab / ⌃⇧Tab 前后切。
- ⌘W 关 SSH 标签（本地标签按现有设计不可关，`TerminalTabBar.swift:131-141` 已如此；
  ⌘W 在只剩本地会话时**什么都不做**并回一声弱提示，不能静默吞键）。
- ⇧⌘N 新建 SSH 会话（对齐 Terminal.app / iTerm2 的新建语义）。
- 侧栏会话列表加 ↑↓ + ↵，或直接并进 F4 的命令面板。

**为什么值得**
标签栏是用户视线焦点区，现在是纯鼠标区。补 6 个键位就能把「抬头找标签」变成「手不离键盘」。

**成本 / 风险**
- 工作量 S。全部走 `CogniTermApp.swift` 的 `.commands`，
  要求按现有惯例加**焦点守卫**（`.disabled(!focus.isTerminalFocused)`），否则在输入框里按 ⌘1 会切标签。
- 唯一需要小心的是 ⌘1-9 与「标签」语义绑定后，将来做分屏（⌘D）时数字键要不要按窗格走——先留一句话在代码注释里。

### F3｜Composer 变成真输入台

**做什么**
1. 高度自适应（2 行起，最多 ~10 行后内部滚动）。
2. **拖文件/目录进来** → 插入转义后的路径（`~/x` 优先缩写成 `~`）。
3. **⌘V 粘图** → 存到临时目录并作为附件发（dsh 的 prompt 目前只吃文本，
   所以要先确认 ACP 是否支持 image content block，见决策点 3）。
4. **↑ 调历史**（当前会话内，最近 20 条；输入框里有内容时 ↑ 仍然是正常光标移动）。
5. 对话区选中文本 → 「引用到输入框」（把链路 3 的缺失补成对称的）。

**成本 / 风险**
- 工作量 M（1、2、4、5 都是 S，3 取决于协议）。
- 风险：TextEditor 是 SwiftUI 原生控件，接管 ↑ 键要包 `NSTextView`，
  是本次唯一需要碰 AppKit 的地方。可以先只做 1/2/5，把 ↑ 历史留到后面。

### F4｜命令面板（⌘P）

**做什么**：一个输入框同时搜 动作 / 会话标签 / 历史会话 / SSH 书签，回车执行。
**为什么不是 ⌘K**：⌘K 已经是「清屏」（`CogniTermApp.swift:69`），事实标准不能抢。
**价值**：解决 discoverability（现在 13 个菜单项藏在菜单里），并且**顺带给侧栏会话补上键盘入口**。
**风险**：容易做成「和菜单重复的第二个入口」。约束：面板只收**有快捷键的动作** + **会话切换**，
不再复制一遍鼠标流程，否则维护两份。

### F5｜审批的两处补强

1. **拒绝时给一句理由**（可空）：拒绝 → 弹出单行输入 → 作为 reject 的 message 回给 agent。
   先要核对 ACP 的 `session/request_permission` 响应是否支持带文本；不支持就退化成本地记录 + 下一轮 prompt 自动附上。
2. **待处理总量**：两张卡（ACP 权限 + 终端命令）同时挂起时，标题区显示「2 项待处理」。

**成本** S/M。风险低，但 1 需要先读 ACP 规范，不能拍脑袋。

---

## 五、我建议的推进顺序

```
第一轮  F2 标签键盘层(≈1 天)  →  F1 Markdown + 代码块执行
第二轮  F3 Composer 1/2/5  →  F5 审批补强
第三轮  F4 命令面板  →  F3-3 粘图（等 ACP 能力确认）
暂不做  字体/主题、OSC 133、QuickSelect、分屏、Warp blocks（理由见下）
```

**为什么不先做字体/主题**：它影响的是「喜不喜欢」，不是「快不快」。
**为什么 OSC 133 往后**：它依赖改用户 dotfile，收益是「命令间跳转」，等有 ⌘↑↓ 需求再说。
**为什么不做分屏**：竖向空间已经要分给对话区，标签的信息密度更高（这条在上一份文档里论证过，结论没变）。

---

## 六、需要你拍板的决策点

| # | 决策 | 选项 | 我的建议 |
|---|---|---|---|
| 1 | Markdown 渲染范围 | **A** 自研最小集（code/列表/粗体/链接，约 250 行）；**B** 引入 apple/swift-markdown；**C** 不做渲染，只识别 ``` 块加按钮 | **A**。仓库现在只有一个 vendored 依赖（SwiftTerm），为渲染引 cmark 不划算；而且我们要的恰恰是「克制」——正文保持裸文本，只有代码块有装饰。C 的问题是长回答里的列表、粗体全是噪音 |
| 2 | 代码块「运行」的默认语义 | **A** 点击=插入待执行（用户自己按 ↵）；**B** 点击=直接跑（过审批后自动 ↵）；**C** 两个按钮分开给 | **C**，但主按钮是「插入」，次按钮「运行…」需要长按/⌥ 才出现，避免误触把危险命令直接送进 shell |
| 3 | 粘图怎么实现 | **A** 先探测 ACP 是否支持 image block，支持才做；**B** 先把图片存临时文件、只把**路径**发给 agent；**C** 不做 | **B 兜底、A 优先**。B 在任何 agent 上都能用（agent 自己去读文件），代价是绕一圈 |
| 4 | 标签键位是否占用 ⌘1-9 | **A** 占用；**B** 只做 ⌃Tab 前后切 | **A**。这是 macOS 的事实标准，用户零学习成本；分屏真做了再讨论窗格编号 |

---

## 七、验证方式（沿用本仓库的判据传统）

- **F1**：纯函数解析器单测（给一段真实 agent 回复，断言切出的块序列）；
  「运行」路径必须有用例证明**它过了审批门**——不能只断言命令进了 PTY。
- **F2**：键位映射单测（对齐 `testTerminalShortcutMappingMatchesITerm2Keys` 的写法）+ 焦点守卫用例。
- **F3-2**：拖放的纯逻辑（路径转义 + `~` 缩写）单测，不依赖真拖拽。
- **端到端**：真起 shell，断言「子进程看到什么」，参考
  `testShellSeesSanitizedEnvironmentAndItsOutputLandsInTheTerminalBuffer`。
- 每个特性都要能在**没有 agent**（无 Key）的情况下单独手工验证，否则不算做完。

---

## 八、本轮已落地（2026-10-26）

第一轮按计划先做 F2、再做 F1。决策全部取上一节建议：自研最小 Markdown、
「运行」为主按钮但危险命令二次确认、占用 ⌘1…⌘9。

| 项 | 落地内容 | 关键文件 |
|---|---|---|
| **F2 标签键盘层** | ⌘1…⌘9 按位置激活（单标签时不显示这组菜单项）、⇧⌘[ / ⇧⌘] 循环、⌘W 只关 SSH（只剩本地会话时键位落回系统「关闭窗口」）、⇧⌘N 新建 SSH | `Services/SessionManager.swift`（`activateTab/cycleTab/nextTabIndex/closeActiveTabIfPossible`）、`CogniTermApp.swift`、`Services/AppCommandCenter.swift`（新建）、`Views/MainSplitView.swift` |
| **F1a 解析器** | 纯函数 `MarkdownParser`：fence / 段落 / 无序 / 有序 / 标题→粗体 / 水平线丢弃；行内 code、粗体、链接、裸 URL、裸路径 | `Models/MarkdownParser.swift`（新建）、`Tests/CogniTermTests/MarkdownParserTests.swift`（13 例） |
| **F1b 动作条** | 代码块卡片带语言标签与「复制 / 插入 / 运行」；插入=键入不回车并交焦点；运行前过 `RiskEvaluator`，高风险在块下方展开确认条；输出经 `runCommandCaptured` 回喂 agent | `Views/MarkdownMessageView.swift`（新建）、`Views/TrajectoryView.swift`、`Views/MainSplitView.swift`（`runCommandFromMessage`） |
| 顺带 | 演示模式的回复改成带 Markdown 的内容——这是**不接真模型**也能看到动作条的路径 | `Services/DemoPeer.swift` |

### 这轮踩到的坑（值得记住）

1. **⌃Tab 方案直接作废**。SwiftTerm 的 `keyDown` 只在 `modifierFlags.contains(.command)`
   时才把键问一次 `NSApp.mainMenu`（`MacTerminalView.swift:2055`）——⌃Tab 不带 Command，
   会被原样发给 shell，菜单项等于不存在。所以循环切换用 ⇧⌘[ / ⇧⌘]。
2. **中文标点必须当词边界**。第一版只按空白切词，`TerminalPaneView.swift，见`
   整段成了一个「词」，路径和 URL 一个都认不出来。单测抓到的，不是肉眼看出来的。
3. **多行代码块不给「运行」**。一次把整段塞进 PTY 等于用户没看过就批量执行；
   逐行拆又猜不准哪几行该一起跑。多行只给复制/插入，决定权交回给人。
4. **`open --args` 传不进启动参数**（本机实测，`pgrep -f -- --flag` 命中不到）。
   外观回归改用 DEBUG 下的 UserDefaults 开关 `demoTranscriptOnLaunch`。

### 尚未验证 / 遗留

- ⌘1…⌘9 的**真机键位**没有实测：UI 自动化在这台机器上被 TCC 挡死
  （`osascript … System Events` 报 -10004），菜单项也无法读。逻辑走单测
  （`testActivateTabIgnoresOutOfRangeAndSwitchesByPosition` 等 5 例），
  声明式菜单与既有 13 个菜单项同一套写法。**需要人工按一次确认。**
- 视觉验证走 `docs/images/markdown-blocks.png`：
  `defaults write com.cogniterm.app demoTranscriptOnLaunch -bool YES` 启动即注入示例回复。
- F3（Composer 输入台）、F4（⌘P 命令面板）、F5（审批补强）未动。
- 字体/主题、OSC 133、QuickSelect、分屏：结论不变，仍排在这些之后。

### 测试账

`scripts/run-tests.sh`：App 测试 88 → **106**（MarkdownParser 13 + SessionManager 5），
全量 235、0 失败。

---

## 九、终端宠物（F6，2026-10-26）

模仿 dsh 生态里那种「大肥鱼」陪聊形象，但干的活是**实时补全**：在终端里
跟着你正在敲的那一行给候选，像输入法。落点是终端工具栏右端的一只小东西，
点开是候选气泡，点候选项 = **只键入、不回车**。

### 先说清三个前提（都是查出来的，不是猜的）

1. **dsh 的 bundle 里没有 pet。** `App/Resources/runtime/node_modules/@deepseek-ai/`
   下 300+ 子包，`find -iname "*pet*"` 零命中。那是上游扩展生态，不在我们分发范围内，
   抄不到也不用抄。
2. **应用层原本看不到「当前命令行」。** SwiftTerm core 里 OSC 133 的语义提示
   其实已经实现得很完整（`SemanticPrompt.swift` + `buffer.semanticContent` /
   `semanticInput` + 分组/续行/`k=` 选项），但：**没有任何 shell 侧集成去发这些
   标记**，App 侧也没有公开读取入口。所以「提示符在第几列结束」此刻拿不到。
   `runCommandCaptured` 里那句「没有 OSC 133 时用静默 3 秒启发式」就是这个现状的注脚。
3. **但键盘输入有唯一漏斗。** `TerminalViewDelegate.send(source:data:)`
   （`TerminalPaneView.swift:969`）是键盘、粘贴、鼠标编码进 PTY 的必经之路；
   App 自己发出的（插入、审批卡注入、宠物接受）也都过 `TerminalSession.send`。
   于是**在 `send` 里顺手记一份字节流，就等价于「用户这一行打了什么」**——
   不需要知道提示符长什么样，因为每按一次 ↵ 缓冲区就清空、新行从零开始。

### 结构

| 文件 | 职责 |
| --- | --- |
| `Models/PetInputBuffer.swift` | 影子行缓冲区：字节 → 当前行 + 置信度（`exact` / `stale(原因)`） |
| `Models/PetSuggestion.swift` | 候选项 + 打分（纯函数，无 IO） |
| `Services/PetContextStore.swift` | 历史（`~/.zsh_history` 扩展格式）/ 对话里的命令 / 目录列表 |
| `Views/PetOverlayView.swift` | 工具栏里的宠物本体 + popover 气泡 |

### 三个设计决定

- **失配就说出来，不硬猜。** Tab 补全、↑ 历史、Ctrl-R、⌥← 这些会改写行的按键，
  字节流里反推不出结果 → 一律打成 `stale(原因)`，气泡头直接显示原因，且**只给
  「最常用」不给「按你打的前缀补」**。`exact` 才做行内补全。按一次 ↵ 自动复原。
- **打分带槽位。** 空行时「最常用」4 条 + 「刚聊到的」1 条——否则历史一多，
  agent 说过的那条永远挤不进前五，这条数据线就白接了。
- **接受 = Ctrl-U + 键入 + 不回车。** 先 kill 掉整行再写字，语义与代码块「插入」
  一致：东西落到命令行上，按不按 ↵ 由人决定。高风险候选（过 `RiskEvaluator`）
  标红，第一次点击只是「摆出风险」，第二次才落字。

### 四个坑（都实测踩过）

1. **`repeatForever` 的隐式动画不能再放进工具栏。** 用它做「呼吸」时，
   宠物每启动一次就漂到别处（三次分别落在对话区不同高度），而它自己的角标
   却还在正确位置——一个视图的绘制几何与布局几何脱钩了。删掉呼吸、只留
   有限动画（眨眼）后立刻归位。**判断依据：位置随重启漂移 = 动画层，不是布局层。**
2. **`GeometryReader` 会吃掉提案尺寸。** 放进工具栏 HStack 的按钮标签里会把
   按钮撑开，图形画到别处。尺寸写死成常量（22pt 的小图标不值得响应式）。
3. **ZStack 角落浮层不可靠。** 靠 `.bottomTrailing` 定位的浮层，内容尺寸一变
   （气泡展开）就跟着漂。改成工具栏 HStack 的兄弟视图 + 系统 popover，布局确定。
4. **popover 会在首帧自己弹出来。** 直接绑 `$isExpanded` 时实测启动即展开；
   加一道「点过才允许呈现」的交互闸门（`hasInteracted && isExpanded`）。

已知边界：`~/.zsh_history` 只在首次读、常驻内存，本会话新跑的命令靠「整行前缀
匹配」自己补上；跨会话要 `PetContextStore.invalidateHistory()`。

### 测试账

`scripts/run-tests.sh`：App 106 → **127**（影子缓冲 10 + 打分 7 + 历史解析 4），
全量 0 失败。视觉：`docs/images/pet-idle.png` / `pet-suggestions.png`
（后者是真机截图：终端里已敲 `ls`，气泡给出 `ls -l` / `ls -la ~/CogniTerm`
/ `ls -la`，图例「历史」，底部「点击只键入、不回车」）。
