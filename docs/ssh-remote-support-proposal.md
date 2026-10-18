# SSH 远程会话支持方案（评审稿）

> 状态：待评审。目标：CogniTerm 支持 SSH 远程连接，能力对齐 MobaXterm 的 SSH 会话管理（不含 RDP/VNC/X11）。
> 本文只做设计决策，不含实现；评审通过后按分期落地。

## 0. 结论

**可以实现，且与现有架构的接缝意外地浅。**

实证依据（本地源码）：

| 事实 | 位置 | 含义 |
|---|---|---|
| SwiftTerm 无任何 SSH 依赖 | `Packages/SwiftTerm/Sources/` 全量 grep | 传输与渲染本就解耦 |
| `TerminalProfile` 是纯策略层 | `Packages/TerminalCore/.../TerminalProfile.swift` | `executablePath + arguments + environment`，可单测 |
| `PseudoTerminal.launch(config)` 接受任意可执行文件 | `TerminalCore` | 换成 `/usr/bin/ssh` 即 SSH 会话 |
| `TerminalCommandExecutor` 面向「任一 PTY」 | `TerminalPaneView.swift` | agent 的 run_in_terminal 天然可指向 SSH 会话 |
| 外层 sb 已 `(allow network-outbound)` | `sidecar.sb`（TRANSPORT 修复的产物） | 22 端口 egress 已放行，无新增沙箱工作 |

即：**SSH 会话在架构上等于「子进程从 zsh 换成 ssh」**，新增成本集中在会话管理与书签，不在传输层。

## 1. 架构接缝

```
[本地 zsh] [ssh 直连] [ssh 跳板]        ← 新增：多会话 + 书签
        ↓
PseudoTerminal · forkpty                ← 零改动（只换 executablePath）
        ↓
SwiftTerm 渲染 · 输出泵 · ⌘I 送屏       ← 零改动
        ↑
TerminalCommandExecutor ← MCP 门 ← agent ← 复用（runCommandCaptured 面向任一 PTY）
```

## 2. 决策点 1：SSH 传输路线（三选一）

| 维度 | A. 系统 ssh 二进制 + PTY | B. NMSSH（libssh2，ObjC） | C. swift-nio-ssh（Apple，纯 Swift） |
|---|---|---|---|
| 依赖 | **零**（`/usr/bin/ssh` 系统自带） | libssh2 + OpenSSL（vendored C 二进制） | SwiftNIO 全家桶（纯 Swift，无 C） |
| 功能完整性 | OpenSSH 全量：ProxyJump / ControlMaster / ssh-agent / 证书 / keyboard-interactive / `~/.ssh/config` / known_hosts | 完整客户端（**iTerm2 实证在用**），SFTP/SCP 内置 | 密码 / 公钥 / hostbased；**缺 keyboard-interactive（issue #136）与 agent 支持（issue #189）** |
| 程序化控制（SFTP / 转发） | 弱（只能解析终端流） | 强 | 强，但需自建会话层（底层 ChannelHandler 库） |
| 凭据与主机校验 UI | 终端内交互（iTerm2 同款行为） | 可自绘 + Keychain 托管 | 需自建 |
| 工程量 | **数天** | 数周 | 数周+ |
| 维护风险 | 零（跟随系统 OpenSSH） | ObjC 老库，但有 iTerm2 长期背书 | 0.15.0（2026-07）活跃，但 issue 积压（#136/#189 多年未解） |

**推荐：A 打底（P1），B 作为 P2 能力升级；C 不选**——缺 keyboard-interactive 与 agent，对真实服务器（尤其带 2FA 的）基本不可用，且底层库意味着 SFTP 也要自己写。

## 3. 决策点 2：范围分期

### P1 — SSH 终端化（A 路线，数天）
- **会话管理**：`TerminalSession.shared` 单例 → `SessionManager`（本地 + N 个 SSH 会话）；快捷键作用于 focused session
- **SSH 书签**（SwiftData）：host / port / user / identityFile / jump host / 启动命令
- **`TerminalProfile.ssh(...)` 纯策略 + 单测**：host 含空格/特殊字符、端口非法值、跳板链拼装
- **侧栏「会话」列表 + 新建表单**；MCP executor 可指向 focused session（agent 远程执行，审批卡不变）
- 明确不做：保存密码（Keychain）、SFTP、端口转发

### P2 — 程序化能力（B 路线，数周）
- NMSSH/libssh2 vendored → **SFTP 文件浏览器**（MobaXterm 标志功能）、端口转发、Keychain 凭据库、host key 校验 UI

### P3 — agent over SSH（可选，需单独评审）
- workspace 跟随远程会话（fs 工具 / 沙箱语义大改，风险高，不默认做）

## 4. 决策点 3：多会话改造的爆炸半径（P1 真正的成本）

| 受影响的既有假设 | 现状 | 改造 |
|---|---|---|
| `TerminalSession.shared` 单例 | Scene 菜单（快捷键）、`TerminalFocus.shared`、MainSplitView、MCP executor 均引用 | 引入 `SessionManager` 持有 `[Session]`；`TerminalFocus` 增加 sessionID |
| 输出收敛启发式 | `runCommandCaptured` 的静默 3 秒判定按单 PTY | 按会话隔离收敛状态 |
| `pendingDirectorySync` / cwd 提示 | 单会话语义 | 远程会话的 cwd 与本地 workspace 无关，需重新定义提示 |
| MCP 审批卡 | 单执行器 | 卡上标注目标会话（本地 / user@host），避免「不知道命令跑哪去了」 |

## 5. 决策点 4：安全与沙箱

- **网络**：外层 sb 已放行 network-outbound → 22 端口无需新增规则；app 进程本身不受 sb 约束（sb 只套 sidecar）
- **host key**：A 路线由系统 ssh 处理（终端内 fingerprint 确认），与 iTerm2 一致；P2 可做 UI 化 + known_hosts 管理
- **密码**：A 路线下用户直接在终端输入（终端应用标准行为）；「保存密码」属 P2 Keychain
- **agent 远程执行语义**：命令对用户可见 + 审批卡不变；但 agent 的 workspace 仍为本地 → 定位为「执行通道」，不宣称文件操作在远端

## 6. 与 MobaXterm 的功能映射

| MobaXterm 能力 | P1 | P2 | 不计划 |
|---|---|---|---|
| 会话书签 / 分组 | ✓（分组后置） | | |
| SSH 多标签 | ✓ | | |
| SFTP 浏览器 | | ✓ | |
| 端口转发 | | ✓ | |
| X11 转发 | | | ✓ |
| RDP / VNC | | | ✓ |

## 7. 待评审决策

1. 路线是否按「**A 打底 + B 升级**」？（备选：直接 B 路线一步到位）
2. 「保存密码 / Keychain 凭据」是否进 P1？（影响 P1 工期与安全评审）
3. agent 对 SSH 会话执行命令：P1 默认开启，还是显式开关？（默认开启更贴合「缝合」定位）
4. 多标签 UI 形态：底部 tab 还是侧栏会话列表+单终端？（倾向后者，与现有侧栏一致）

## 8. 实施记录（P1 已落地，2026-10-18）

决策全部按上文倾向执行（A 路线 / 不存凭据 / agent 默认可执行 / 侧栏会话列表）。代码落点：

| 关注点 | 实现 |
| --- | --- |
| 连接策略 | `Packages/TerminalCore/Sources/TerminalCore/SSHTarget.swift`（`SSHTarget` + `TerminalProfile.ssh`，纯层可单测，零依赖） |
| 多会话 | `App/Sources/Services/SessionManager.swift`（`sessions` / `activeSessionID` / executor 委托） |
| 每会话常驻渲染 | `MainSplitView` 的 `ZStack + ForEach`（切会话不重建 NSView，scrollback 与运行中命令保留） |
| 会话与书签 UI | 侧栏「终端」「SSH 书签」两节 + `App/Sources/Views/NewSSHSessionSheet.swift` |
| 书签持久化 | `Persistence.Models.SSHBookmark`（**不含任何凭据字段**） |
| agent 执行平面 | `SessionManager: TerminalCommandExecutor`；审批卡显示「目标终端：本地 / user@host」 |
| 安全边界 | argv 不进 shell，`isSafeToken` 拒前导 `-`（`-oProxyCommand` 注入）；私钥路径 `~` 由代码展开 |

验证：
- `SSHTargetTests` 12 条（校验、注入、参数顺序）+ 1 条**真进程**用例：用生产同款 `profile.ptyConfig(...)` 真跑 `/usr/bin/ssh` 打本机高位端口，断言 ssh 自己报 `Connection refused` —— 证明「Profile → PTY → ssh」整链成立。
- `SessionManagerTests` 7 条（增量开/切/关、本地不可关、executor 委托与 fail-fast）。
- 全量 173 测试 0 失败；已安装 `/Applications/CogniTerm.app` 实例 MCP 正常、sidecar 从 bundle Resources 启动。

P1 明确**不做**：密码/Keychain 凭据库、SFTP 面板、端口转发、跳板管理 UI、会话分屏。这些属 P2/P3，接缝已留（`SSHTarget` 增字段 + `TerminalProfile.ssh` 增 argv）。
