# CogniTerm 终端交互升级方案

> 起因（2026-10-17）：**"我们的 terminal 连 mac 自带的 zsh 体验感都不如"**。
> 本文先做现状盘点（全部带代码引用），再对照开源终端的交互设计，
> 最后给分层实施计划 + **需要拍板的决策点**。
>
> 本轮已落地 P0（无设计分歧、纯缺口的四件事），见第五节。

---

## 一、先分清：终端模拟能力 vs 交互层

排查后有个重要结论：**我们的"难用"几乎全在交互层，不在终端模拟能力。**

`Packages/SwiftTerm`（vendored 上游）已经提供：

| 能力 | 状态 | 代码位置 |
|---|---|---|
| VT 解析 / 备用屏 / 滚动回看 / 选区复制 / IME | ✅ | `Packages/SwiftTerm/Sources/SwiftTerm/` |
| OSC 8 超链接 | ✅ | `Apple/AppleTerminalView.swift` |
| SGR 鼠标（1006）、括号粘贴（2004） | ✅ | `Terminal.swift` |
| Sixel / Kitty 图形协议 | ✅ | `SixelDcsHandler.swift`、`KittyGraphics.swift` |
| Kitty 键盘协议 | ✅ | `KittyKeyboardProtocol.swift` |
| 查找（自带 find bar + NSTextFinder） | ✅ | `Mac/MacFindBarView.swift`、`TerminalViewSearch.swift` |
| **OSC 133 语义提示标记**（prompt/命令边界） | ✅ 底座有，**未接线** | `SemanticPrompt.swift`、`Terminal.swift:2816/2840/2845` |
| 滚动 API（`scroll(toPosition:)` / `scrollTo(row:)`） | ✅ | `Apple/AppleTerminalView.swift:4295/4321` |

也就是说：vim / less / htop / 颜色 / 鼠标 / 图形这些"能不能用"早就没问题了
（见 `TerminalIntegrationTests.testTerminalParsesControlSequencesInsteadOfStrippingThem`）。
缺的是**怎么让人用得顺**。

---

## 二、现状盘点：我们到底缺什么（全部有代码出处）

| # | 缺陷 | 证据 | 用户可感知的症状 |
|---|---|---|---|
| 1 | **一个键盘快捷键都没有** | `grep -rn keyboardShortcut App/Sources/` 只命中审批卡/输入框/引导页，终端 0 处；`CogniTermApp` 没有 `Commands` 块 | 清屏/查找/重启只能拿鼠标点工具栏小图标 |
| 2 | **滚动委托是空实现** | `TerminalPaneView.swift` 原 `func scrolled(source:position:) {}`，注释写着"将来可以做一个回到底部的按钮" | 往上翻了只能手动拖滚动条；`tail -f` 时新输出静默滚走 |
| 3 | **bell 默认系统蜂鸣** | SwiftTerm 默认 `NSSound.beep()`（`Mac/MacTerminalView.swift:4817`） | 跑构建/测试连续 BEL，噪音骚扰 |
| 4 | **OSC 52 剪贴板是空操作** | SwiftTerm 默认 `clipboardCopy` 为空（`Mac/MacTerminalView.swift:4825`），我们没实现 | vim 里 yy、tmux/嵌套 ssh 同步剪贴板全线静默失败，且无任何报错 |
| 5 | **只有字号可调，没有字体族/主题/光标/透明度** | `NSFont.monospacedSystemFont` 写死（`TerminalPaneView.swift`）；`SettingsView` 里没有任何终端项 | 想换 JetBrains Mono / 想要暖色主题，没入口 |
| 6 | **单终端，无标签、无分屏** | `MainSplitView:200` 只有一个 `TerminalPanel(session: terminal)` | 同时开构建+日志+ssh 就得来回切，或另开 Terminal.app |
| 7 | **OSC 133 语义提示未接线** | `TerminalSession` 从不调用 `semanticPromptMarks/activeSemanticPromptOrigin` | 没有提示行标记、不能在命令间跳转、看不到命令耗时 |
| 8 | **没有 URL hints / QuickSelect** | 无 | 一屏里的链接只能拿鼠标精确点中 |
| 9 | **没有命令面板** | 无 | 功能 discoverability = 0，全靠鼠标悬停看 tooltip |
| 10 | **会话不恢复** | app 重启即丢 | 每天第一次开机要重新 `cd` / 起服务 |

---

## 三、开源终端的交互设计对照

键位/交互一栏以「事实标准」为准（macOS 用户换终端不用重新学）：

| 能力 | iTerm2 | kitty | WezTerm | Warp | Ghostty | 我们 |
|---|---|---|---|---|---|---|
| Cmd-K 清屏 / Cmd-F 查找 / Cmd-R 重启 / Cmd-. 中断 / Cmd-± 字号 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌→**P0 已补** |
| 回看浮层 + 未读计数 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌→**P0 已补** |
| bell 视觉化/可关 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌→**P0 已补** |
| OSC 52 剪贴板 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌→**P0 已补** |
| 多标签（Cmd-T / Cmd-W） | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 分屏（Cmd-D / Cmd-Shift-D） | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Shell 集成（OSC 133：提示标记、命令间跳转、耗时） | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ 底座有未接线 |
| URL / 文本 hints（按一个键给候选编号） | ✅ Smart Selection | ✅ kittens | ✅ QuickSelect | ✅ | ✅ | ❌ |
| 命令面板 | ✅ | ✅ | ✅ Launcher | ✅ | ✅ | ❌ |
| 字体族 / 配色主题 / 光标形状 / 透明度 | ✅ Profile | ✅ conf | ✅ | ✅ | ✅ | ❌ |
| 会话恢复 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 广播输入到所有分屏 | ✅ | ✅ | ✅ | — | ✅ | ❌ |
| 输出时间戳切换 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Triggers（输出正则 → 动作） | ✅ | — | ✅ | ✅ | — | ❌ |
| Warp 式 blocks（命令+输出为一个单元） | — | — | — | ✅ | — | ❌ |

---

## 四、本轮已落地：P0（无设计分歧、纯缺口）

四项，都是"别人有、我们没有、且不存在第二种合理做法"的：

| 改动 | 文件 | 说明 |
|---|---|---|
| **键盘快捷键** | `App/Sources/CogniTermApp.swift` + `App/Sources/Views/TerminalPaneView.swift` | ⌘K 清屏 / ⌘F 查找 / ⌘R 重启 / ⌘. 中断 / ⌘+ ⌘- ⌘0 字号。实现是 **Scene 级 `Commands` 菜单项**，**带焦点守卫**（见下） |
| **回看浮层 + 未读计数** | 同上 | 离开底部时右下角浮出「回到底部 ↓N」；翻历史期间的新输出计数 |
| **bell 改视觉提示** | 同上 | 标题图标闪橙 1.5s，不再蜂鸣 |
| **OSC 52 写剪贴板** | 同上 | vim/tmux/嵌套 ssh 的剪贴板同步恢复；**读方向仍默认拒绝**（远端读本地剪贴板需显式同意） |

两个实现要点（都是踩过的坑）：

1. **快捷键必须走宿主菜单，不能覆盖 `performKeyEquivalent`**。
   第一版就是覆盖它，直接编译失败：SwiftTerm 里该方法是 `public override`（**非 open**），
   模块外禁覆盖。读上游 `keyDown` 源码发现它显式写了
   *"The host menu owns its shortcuts"* —— 带 Command 的键它会先问一次
   `NSApp.mainMenu?.performKeyEquivalent`，菜单接了就不再发给 shell。
   所以正确路径就是装菜单项，让 AppKit 的既有机制干活。
2. **焦点守卫不能省**：菜单项在 App 里到处都按得到。不区分焦点就会在聊天输入框里
   按 ⌘K 把终端清屏、按 ⌘R 把 shell 重启。焦点由 `CogniTerminalView` 在
   `become/resignFirstResponder` 里发布给 `TerminalFocus.shared`，
   菜单项用 `.disabled(!isTerminalFocused)` 消费（失焦时 key equivalent 不消耗、
   自动落给聊天输入框）。之所以不用 SwiftUI focus 环境值：中间隔着
   `NSViewRepresentable`，SwiftUI focus 系统看不到 NSView 的焦点。
   测试：`testTerminalFocusTracksFirstResponderChanges`。
3. **⌘C / ⌘V / ⌘A 不接管**：SwiftTerm 自己实现了 `copy(_:)` / `paste(_:)` /
   `selectAll(_:)` responder 动作（`Mac/MacTerminalView.swift:3415/3434/3446`），
   走 `keyDown → interpretKeyEvents → doCommand` 路径，和系统 Edit 菜单天然配合。
   再包一层菜单项只会把标准行为复制一遍。
4. **只映射"终端面板自己的功能"**：shell 需要的键一个都不碰（方向键、Tab、
   Ctrl-R、Ctrl-C、Ctrl-A/E 全部走 `send(source:data:)`）。带 Ctrl/Option 的
   Command 组合也不碰 —— 那是 kitty 键盘协议的领域。
   测试：`testTerminalShortcutMappingMatchesITerm2Keys`。

同时补了测试（键位映射、焦点状态机进出、字号档位夹取、回看态进出、
`scrollToBottom` 位置不变时也归位、bell 自动收回、端到端环境 sanitize）。
基线：CogniTermTests 25 → **36**（其中 TerminalIntegrationTests 5 → 11）。

### 本轮顺带修掉的两个「接线」问题（比快捷键本身更值得记住）

1. **`TerminalIntegrationTests.swift` 从来没被编译过**：pbxproj 的 Tests group /
   Sources phase 里没有它（之前重建 pbxproj 时漏了）。症状是「改了测试、
   跑了 run-tests.sh、看到全绿」—— 绿的是一份从未包含新测试的 bundle。
   修法：pbxproj 补 file reference + build file + group + Sources phase。
2. **`import SwiftTerm` 一直靠在 DerivedData 里的陈旧模块产物**：pbxproj 从未
   引用 SwiftTerm 包（没有 `XCLocalSwiftPackageReference` 也没有 product
   dependency），`import` 靠 BUILT_PRODUCTS_DIR 的隐式搜索路径命中 10-16
   遗留的旧 swiftmodule。所以改 SwiftTerm 源码（`public override` → `open
   override`）**一开始完全不生效**，报错依旧是旧的。修法：pbxproj 补本地包
   引用 + 两个 target 的 `packageProductDependencies` + Frameworks phase，
   并跑一次完整 `build-app.sh` 验证框架 embed。
   > 教训：「编译过了」≠「编的是你改的那份」——源码改了没生效，
   > 先查它到底进没进依赖图。

验证：`scripts/run-tests.sh` 36 测试 0 失败；`scripts/build-app.sh` 产物校验
全过（含 SwiftTerm 框架 embed）；已安装 /Applications/CogniTerm.app。

---

## 五、待评审：P1（有设计决策，需要你拍板）

### 决策点 1：终端布局 —— 多标签 / 分屏 / 保持现状

| 选项 | 做法 | 工作量 | 风险 |
|---|---|---|---|
| **A. 多标签**（推荐先做） | 顶栏一排标签，⌘T 新建 / ⌘W 关闭 / ⌘1-9 切换；每个标签一个 `TerminalSession` | 中（需要把 `TerminalSession` 从 `@StateObject` 单例改成集合，`MainSplitView` 加标签栏） | 低：不动会话逻辑，只动容器 |
| B. 分屏 | ⌘D 竖分 / ⌘-⇧D 横分，每格一个 session | 中高（要处理分屏内的焦点、尺寸变化广播） | 中：`NSViewRepresentable` 嵌套分屏的尺寸回调容易出错 |
| C. A+B | 先标签后分屏 | 高 | — |
| D. 保持现状 | 继续用系统 Terminal.app 跑多任务 | 0 | 体验持续被比下去 |

**我的建议：A**。标签的信息密度比分屏高（我们下面还有聊天区，竖向空间本来就紧），
而且 ⌘T/⌘W/⌘1-9 是零学习成本的系统惯例。

### 决策点 2：Shell 集成（OSC 133）怎么注入

底座支持（`Terminal.swift:2816 semanticPromptMarks(at:)`），但**要 shell 侧发 OSC 133 才有数据**。
三种注入方式：

| 选项 | 做法 | 侵入性 | 说明 |
|---|---|---|---|
| **A. 只读环境变量 + 可选一键安装**（推荐） | 默认只注入 `TERM_PROGRAM` 等；设置里给一个「安装 shell 集成」按钮，它备份后往 `~/.zshrc` 追加一段（iTerm2 同款做法，可卸载） | 低 | 用户明确同意才改 dotfile；不装则功能静默不可用，但没有任何副作用 |
| B. 启动时临时注入 `ZDOTDIR` | 指向我们提供的一份 `.zshrc`，里面 source 用户原配置 | 中 | 会改变 zsh 的启动路径，某些配置（`~/.zlogin`、插件管理器）可能行为变化 |
| C. 不做 | — | 0 | 放弃「命令间跳转 / 耗时显示 / 提示标记」 |

**我的建议：A**。换来的功能：提示行左侧标记、⌘↑/⌘↓ 在命令间跳转、
每条命令显示耗时（长构建时很香）。iTerm2 就是这么做的，用户心智成本最低。

> ⚠️ 无论选哪个，**都不能默认改用户的 dotfile** —— 那是别人机器上的个人文件，
> 必须显式同意 + 可卸载 + 先备份。

### 决策点 3：字体 / 主题设置面板的范围

| 选项 | 内容 | 工作量 |
|---|---|---|
| A. 最小 | 字体族（SF Mono / Menlo / JetBrains Mono / Fira Code / Iosevka）+ 字号 + 行高 | 小 |
| **B. 中等（推荐）** | A + 配色主题（跟随系统 / 8 套预设）+ 光标形状与闪烁 + 终端内边距 | 中 |
| C. 完整 | B + 透明度/毛玻璃 + 每主题可编辑 | 高 |

**我的建议：B**。C 的收益/复杂度比很差，而且透明度在有聊天区的布局里容易显得脏。

> 实现约束：要新增设置字段，按仓库约定走 **SwiftData 可空字段 + 读路径回落**，
> 不能改旧 store 的 schema 语义。

### 决策点 4：URL / 文本 hints（QuickSelect）

kitty 的 kittens / WezTerm 的 QuickSelect：按一个键（如 ⌘-⇧-Space 或 F1），
屏幕上的 URL / 路径 / 数字 / 邮箱全部获得字母编号，再按字母即复制或打开。
**这是"少用鼠标"最有效的一个功能**，但需要自己扫缓冲区拿屏幕坐标 + 叠层 + 捕获按键，
预计 200-300 行。

**我的建议：做，但排在 P1 最后**（价值高、风险也高，容易和选区/鼠标上报打架）。

---

## 六、P2（价值明确但可以更晚）

| 项 | 开源依据 | 说明 |
|---|---|---|
| 命令面板（⌘P） | kitty / WezTerm Launcher / Warp | 把所有终端动作（含 P1 新增）集中到一处，顺带解决 discoverability |
| 会话恢复 | iTerm2 / kitty / Ghostty | app 重启后恢复标签与 cwd；重放 scrollback 需要落盘，较重 |
| 广播输入 | iTerm2 / kitty / WezTerm | 多标签同时执行同一命令 |
| 输出时间戳 | iTerm2 ⌘-⌥-E | 按行显示时间 |
| Triggers | iTerm2 / WezTerm | 输出正则 → 高亮/通知/执行动作 |
| Warp 式 blocks | Warp | 把「命令 + 输出」做成一个可折叠单元；与我们的 ACP 对话流天然契合，但改动最大 |

---

## 七、建议的推进顺序

```
P0（本轮已完成） 快捷键 / 回看浮层 / bell / OSC 52
        ↓
P1-a 多标签（⌘T ⌘W ⌘1-9）          ← 决策点 1，建议 A
P1-b Shell 集成（OSC 133）           ← 决策点 2，建议 A；附带 ⌘↑⌘↓ 命令跳转
P1-c 字体/主题/光标设置              ← 决策点 3，建议 B
P1-d URL hints / QuickSelect        ← 决策点 4，建议做但排最后
        ↓
P2 命令面板 → 会话恢复 → 广播/时间戳/triggers → blocks
```

每一步都可独立验证、独立回滚；不引入跨步骤的隐式依赖。

---

## 八、验证方式（延续本仓库的判据传统）

- **单测**：键位映射、焦点守卫、状态机（回看态、bell）走纯函数/可注入路径，
  不依赖真 shell（参考 `TerminalIntegrationTests` 现有写法）。
- **端到端**：真起 shell、断言「子进程看到什么」+「终端缓冲区里有什么」，
  参考 `testShellSeesSanitizedEnvironmentAndItsOutputLandsInTheTerminalBuffer`。
- **沙箱类改动**：必须 `scripts/probe-sandbox-network.sh`，不能只做文本断言
  （2026-10-16 的教训：`sidecar.sb` 文本全对、语义全错）。
