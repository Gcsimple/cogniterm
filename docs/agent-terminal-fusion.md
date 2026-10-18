# Agent 聊天框 × Terminal 融合研究

> 起因（2026-10-17）：**「agent 聊天框和 terminal 融合的也不够友好」**。
> 本文先解剖现状（全部带代码引用），再给出断层分析、开源对标、方案空间与决策点。
> **本文是研究稿，不改代码**——按评审驱动工作流，等拍板后再进入实现。

---

## 一、一句话结论

「不友好」的根因不是布局丑，是**产品里有两个互不知晓的执行平面**：
用户的手动 shell（我们的 PTY）和 agent 的工具执行平面（dsh 自己跑，不过我们的 PTY）。
布局、快捷键、复制粘贴都只是这个根因的表症。

---

## 二、现状解剖：两个执行平面

### 2.1 布局（`App/Sources/Views/MainSplitView.swift:183-203`）

```
NavigationSplitView
├─ sidebar：sidecar 状态 / 会话配置 / 工作区 / 历史会话 / 诊断
└─ detail：VSplitView（上下分）
   ├─ 上：TrajectoryView（对话流）+ ApprovalCardView（审批卡）+ ComposerView（输入框）
   │     .frame(minHeight: 320)
   └─ 下：TerminalPanel（终端）  .frame(minHeight: 140)
```

终端是**二等公民**：最小高度 140pt、无比例记忆、无标签。

### 2.2 agent 的命令不走终端（关键事实）

- 终端面板只包 `PseudoTerminal`（`TerminalPaneView.swift` 的 `TerminalSession`），
  跑的是**用户手动交互的 shell**。
- agent（dsh）的工具调用在 node 侧自己执行，结果经 ACP `toolCallUpdate` 的
  `resultText` 回到对话流——`ConversationModel.swift:130-138` 把它**纯文本追加**
  到 tool 行：`rows[index].text += "\n→ \(result)"`。
- 后果一：用户在终端里看不到 agent 跑了什么，只能回对话流看。
- 后果二：tool 行的长输出 / ANSI 输出（带颜色的测试报告）以纯文本堆在气泡里，
  没法看、没法交互。

### 2.3 终端输出进不了 agent 上下文

- `ComposerView` 是纯 `TextEditor`，没有任何「引用终端内容」的入口。
- 用户想把一段 build 错误发给 agent：手动复制 → 手动切焦点 → 手动粘贴。
- 反向也没有：用户在终端里 `cd`/跑了什么，agent 完全不知晓。

### 2.4 目录状态双轨（`MainSplitView.swift:248-263`）

- `applyWorkspace()` 同时写三份：`sidecar.workspaceRoot` /
  `conversation.workspaceRoot` / `terminal.workspaceRoot`。
- 但终端侧用户自己 `cd` 后（OSC 7 → `observeShellDirectory`，`TerminalPaneView.swift:437`），
  **只更新终端自己的标题，不通知 conversation**——审批卡 `RiskEvaluator` 用的
  `cwd` 还是旧 workspaceRoot（`ApprovalCardView.swift:29`）。
- 已有「同步目录」按钮（`syncWorkingDirectory`）是**单向**的：
  workspaceRoot → 终端，反方向没有。

---

## 三、四个断层

| # | 断层 | 用户可感知的症状 | 证据 |
|---|---|---|---|
| 1 | **执行平面断层** | agent 跑的命令在终端里看不见；用户在终端跑的错误 agent 不知道 | §2.2 / §2.3 |
| 2 | **上下文断层** | 想把终端输出发给 agent 只能手动复制粘贴 | `ComposerView` 无引用能力 |
| 3 | **状态断层** | 终端 cd 到子目录后，agent 的审批/工具还在旧目录上下文里工作 | §2.4 |
| 4 | **视觉断层** | 上下分屏 + 140pt 终端；tool 行长输出纯文本堆叠；分割比例不记忆 | §2.1 / §2.2 |

---

## 四、开源终端/IDE 怎么解（对标）

| 能力 | Claude Code | Warp 2.0 | VS Code + Copilot | Cursor | 我们 |
|---|---|---|---|---|---|
| 对话与 shell 共享同一执行平面 | ✅（就在 TTY 里） | ✅（blocks + agent 面板） | ❌ | ❌ | ❌ 两个平面 |
| 终端输出一键进 AI 上下文 | ✅ 原生 | ✅ agent 可见终端 | ✅ 选中 → Add to Chat / `@terminal` | ✅ 自动附加终端 | ❌ 手动复制 |
| AI 的命令在终端里可见 | ✅ | ✅ | ❌（后台跑） | ❌（后台跑） | ❌ |
| 目录状态一致 | ✅ 同一 cwd | ✅ | ✅ | ✅ | ⚠️ 双轨 + 手动同步 |

两个值得抄的范式：
- **Claude Code 式「共享 TTY」**：最彻底，但它没有 GUI 终端能力（滚动条、鼠标选区、
  快捷键全没有），和我们「GUI 终端 + agent」的定位相反，**不抄**。
- **VS Code Copilot 式「终端输出 → 聊天上下文」**：选中即引用。
  这是把我们两个平面**用上下文缝起来**，而不是合成一个平面——与我们的架构兼容，**抄这个**。

---

## 五、方案空间（按「缝平面」的思路分四组）

### A. 终端 → agent：上下文注入（解决断层 2，最高频、最低风险）

| 选项 | 做法 | 工作量 | 风险 |
|---|---|---|---|
| **A1. 选区问 agent**（推荐先做） | 终端选中文本后，浮出小按钮 / `⌘↵` → 以「引用块」形式插入 ComposerView（等宽字体 + 可删除的 chip） | 0.5 天 | 低：`TerminalView.getSelection()` 已是公开 API（`Apple/AppleTerminalView.swift:4813`），零上游改动 |
| A2. 最近 N 行引用 | 快捷键（如 `⌘⌥L`）把回看缓冲区最后 N 行作为引用块插入输入框 | 0.5 天 | 低：`getBufferAsData` 公开（`Terminal.swift:8958`） |
| A3. 工具栏「问 agent」 | 终端工具栏加按钮，等价 A1（给不用快捷键的用户） | 0.2 天 | 低 |

### B. agent → 终端：执行镜像（解决断层 1，最「融合」也最重）

| 选项 | 做法 | 工作量 | 风险 |
|---|---|---|---|
| B1. 全量托管 | 关掉 dsh 的 bash 工具，App 侧 PTY 执行后把结果喂回 agent | 3-5 天 | **高**：重构审批语义，agent 能力受限，不推荐 v1 |
| **B2. 审批卡「在终端运行」**（推荐） | 用户批准时选「在终端运行」→ 对 ACP respond **reject**（dsh 不跑）→ 命令注入我们的 PTY（用户可见、可干预）→ 捕获输出 → 自动发一条 prompt 回喂 agent（「命令 X 的终端输出：…请继续」） | 2-3 天 | 中：输出收敛判定（无 OSC 133 时用「静默 N 秒」启发式 + 5 分钟硬超时 + 「跳过回喂」按钮）；交互式命令（vim）会卡——超时即跳过 |
| B3. 轻量版 | 审批卡「复制到终端」：只注入 PTY、不自动回车、不回喂，用户自己跑自己看 | 0.5 天 | 低：纯粹的「让命令可见」，回喂可选 |

### C. 布局与视觉（解决断层 4）

| 选项 | 做法 | 工作量 | 风险 |
|---|---|---|---|
| C1. 分割比例持久化 | VSplitView 比例存 UserDefaults，终端默认 140 → 180 | 0.3 天 | 低 |
| **C2. tool 行输出升级** | tool 行折叠/展开；长输出用迷你 SwiftTerm 视图渲染（ANSI 保真、可滚动）而非纯文本追加 | 1.5 天 | 中：要在 LazyVStack 里嵌 NSViewRepresentable，注意复用 |
| C3. agent 运行时终端标题提示 | sidecar.isWorking 时终端标题闪「agent 运行中」 | 0.2 天 | 低 |

### D. 状态同步（解决断层 3）

| 选项 | 做法 | 工作量 | 风险 |
|---|---|---|---|
| **D1. cwd 自动同步** | `observeShellDirectory` 收到 OSC 7 时同步更新 `conversation.workspaceRoot`（审批卡/规则的 cwd 跟着终端走） | 0.3 天 | 低：单向、可回退；注意只同步不改变 sidecar 的会话 cwd |
| D2. 审批卡显示目录 | 审批卡展示「将在 <目录> 执行」，与终端目录不一致时给提示 | 0.2 天 | 低 |

---

## 六、推荐路线与决策点

### 推荐分三批（每批独立验证、独立回滚）

```
第一批（低风险高感知，~1.5 天）  A1 选区问 agent + D1 cwd 自动同步 + C1 比例记忆
        ↓
第二批（真融合，~2-3 天）        B3 → B2（先注入可见，再自动回喂）
        ↓
第三批（打磨，~2 天）            C2 tool 行迷你终端 + A2/A3 按需
```

第一批直接消掉「复制粘贴」和「目录双轨」这两个每天都会遇到的刺；
第二批才动执行平面，风险可控在后面。

### 需要拍板的决策点

| # | 决策 | 选项 | 我的建议 |
|---|---|---|---|
| 1 | 第一批范围 | A：仅 A1 / B：A1+A2+A3 全做 / C：A1+D1+C1（推荐） | **C**：A2/A3 是锦上添花，等真实用了再说 |
| 2 | B 系列做到哪一步 | A：不做 / B：B3 只注入 / C：B2 自动回喂（推荐） | **先 B3 后 B2**：B3 半天就能用上，B2 的收敛判定值得单独一轮迭代 |
| 3 | 引用块的形态 | A：纯文本插入 / B：chip 块（等宽、可整块删除） | **B**：一眼能看出「这是终端内容」，删起来也干净 |
| 4 | 布局是否动 | A：保持上下分屏只加比例记忆 / B：改左右分屏（对话左终端右） | **A**：左右分屏在 960pt 宽的窗口里两边都太挤；上下分屏 + 记忆比例更稳 |

---

## 七、技术前提（已全部验证可行，零 vendored 改动）

| 能力 | API | 位置 |
|---|---|---|
| 读终端选区 | `public func getSelection() -> String?` | `Apple/AppleTerminalView.swift:4813` |
| 读回看缓冲区（最后 N 行） | `public func getBufferAsData(kind:encoding:)` | `Terminal.swift:8958` |
| 向 PTY 注入命令 | `pty.write`（已有，`syncWorkingDirectory` 同款） | `TerminalPaneView.swift:391` |
| 拦截 agent 的工具执行 | ACP `request_permission` 已在 App 侧审批 | `ConversationModel.swift:234`（`UIAnswerer`） |
| 自动回喂 prompt | `sidecar.client?.prompt(sessionId:text:)` | `ComposerView.swift:84` |

> 注：B2 的「输出收敛判定」若将来接了 shell 集成（OSC 133，P1 决策点 2），
> 可升级为「提示符回来即收敛」，比静默超时精确得多——**B2 排在 OSC 133 之后更稳**。

---

## 八、验证方式（延续本仓库判据传统）

- **纯逻辑单测**：引用块的插入/删除、cwd 同步的状态机、静默收敛的超时行为。
- **端到端**：真起 shell → 注入命令 → 断言「终端缓冲区里的输出」与「回喂给
  agent 的文本」，参考 `testShellSeesSanitizedEnvironmentAndItsOutputLandsInTheTerminalBuffer`。
- **判据落在最终效果**：融合做没做成，看「用户能不能一键把终端错误变成 agent 的
  上下文」和「agent 批准的命令用户能不能在终端里看见」——不是看按钮存不存在。
