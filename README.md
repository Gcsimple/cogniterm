# CogniTerm

**A macOS terminal where the AI agent and your shell share one execution plane.**

一个把 AI agent 和终端缝进同一个窗口的 macOS 原生终端。agent 想执行的命令，最终落在**你能看见、能接管**的那个 PTY 里。

```
macOS 14+ · Swift / SwiftUI · SwiftTerm · ACP · MCP · 无 Electron
```

---

## 为什么做它

现在的 AI 编程工具大多有**两个互不知晓的执行平面**：

- agent 在后台跑命令，你在终端里看不见它跑了什么；
- 你在终端里撞上的报错，想给 AI 看只能手动复制 → 切焦点 → 粘贴。

这两个断层不是布局问题，是架构问题。CogniTerm 的做法是把它们接上：

| 场景 | 别的工具 | CogniTerm |
|---|---|---|
| agent 要跑 `rm -rf build/` | 后台静默执行，事后看日志 | 弹审批卡 → 批准后**注入你的终端**，命令和输出都在你眼前 |
| 你想把一段编译错误问 AI | 选中 → 复制 → 切窗口 → 粘贴 | 终端里选中 → `⌘I` → 以引用块进入输入框 |
| 想连远程机器 | 另开一个 SSH 客户端 | 会话标签页里直接开，agent 的命令发到**当前活跃会话**（本地或远程） |

---

## 核心特性

| 特性 | 说明 |
|---|---|
| **agent 命令走你的终端** | 内嵌 MCP server 暴露 `run_in_terminal`，agent 的工具调用经审批后写入活跃 PTY，输出回喂给模型 |
| **四层权限** | dsh 配置模式 → App 侧 `PolicyEngine`（8 类风险标签 + 词法切分 + 规则沉淀）→ 审批卡 → seatbelt 沙箱 |
| **原生终端** | SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)，鼠标选区、滚动回看、`⌘C/⌘V/⌘A` 都是系统语义 |
| **多会话** | 本地 shell + 任意多个 SSH 远程会话，每个会话独立 PTY、独立画布，切换不重建视图 |
| **实时切换模型** | ACP `session/set_config_option`，无需重启会话；失败不做乐观更新 |
| **会话重放** | 直接读 dsh 的会话日志（JSONL），逐步还原工具调用与审批过程 |
| **终端 → 对话** | `⌘I` 发送选区，`⌘⇧I` 发送当前屏幕末尾 N 行（`>` 引用块，可整块删除） |

---

## 架构

```
┌─────────────────────────────── CogniTerm.app（SwiftUI）───────────────────────────────┐
│                                                                                       │
│  ComposerView ──▶ ConversationModel ──▶ SidecarService ──ACP(stdio)──▶ dsh agent loop  │
│       ▲                                     │                              │          │
│       │                        ┌────────────┴────────────┐                 │          │
│       │                        │                         │                 │          │
│  TrajectoryView          PolicyEngine              Seatbelt profile         │          │
│  ApprovalCardView     （风险标签 / 规则）        sidecar.sb / -writable.sb   │          │
│       ▲                                                                   │          │
│       │                                                         工具调用请求 │          │
│       │                                                                   ▼          │
│  TerminalMCPServer ◀──────────── HTTP /mcp（仅 127.0.0.1，临时端口）────────┘          │
│       │   审批（50s 窗口）→ 等终端空闲 → 注入                                            │
│       ▼                                                                               │
│  SessionManager ──▶ TerminalSession[]  ──▶ PTY ──▶ zsh / ssh                           │
│       │                  ▲                                                            │
│       └── activeSessionID┘   （agent 的执行平面 = 当前活跃会话）                          │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

几条关键取舍：

- **agent 是独立进程**（`dsh` 跑在 node 上，经 ACP 通信），崩溃不影响 App，沙箱也仍然有效。
- **审批门做在 App 侧**：MCP 工具在 dsh 侧不过审批，所以门必须是我们自己的 MCP server——请求到达即弹卡，批准才写 PTY。
- **反向请求不阻塞分帧泵**：工具调用与审批是两条独立流程，用非结构化任务 + 单次 resume 保证既不死锁也不重复回调。
- **沙箱分两档**：只读用 `sidecar.sb`，`workspace-write` 用 `sidecar-writable.sb`（外层兜底，细粒度归内层）。

---

## 快速开始

### 依赖

- macOS 14 (Sonoma) 或更新，Apple Silicon
- Xcode（命令行工具不足，需要完整 Xcode 编译 App 目标）

Node 不需要单独装——运行时随 App 一起 vendor。

### 构建与安装

```bash
git clone https://github.com/Gcsimple/cogniterm.git
cd cogniterm

# 1) 把 node + dsh 运行时 vendor 进 App 包（首次需要，约 50MB）
scripts/vendor-runtime.sh

# 2) 构建（产物唯一：.build/xcode/Build/Products/Debug/CogniTerm.app）
scripts/build-app.sh

# 3) 安装到 /Applications，让 Finder / Launchpad 只认这一份
scripts/install-app.sh --no-build

# 4) 启动
open -b com.cogniterm.app
```

模型 API Key 在 App 的 Settings 里填写，存 macOS Keychain，不落任何配置文件。

### 测试

```bash
scripts/run-tests.sh
```

5 个本地包 + App 目标，共 **217** 个测试，全部通过：

| 目标 | 用例数 |
|---|---|
| `AcpClient` | 42 |
| `TerminalCore` | 32 |
| `App`（CogniTerm） | 88 |
| `Persistence` | 23 |
| `SessionLogReader` | 24 |
| `PolicyEngine` | 8 |

App 测试用「编译测试 bundle + `xcrun xctest` 独立运行」的方式跑，不需要 app host——在无沙箱的常规机器上 `xcodebuild test` 也可以。

---

## 使用要点

| 动作 | 快捷键 / 位置 |
|---|---|
| 把终端选区发给 agent | 选中文本 → `⌘I` |
| 把当前屏幕内容发给 agent | `⌘⇧I` |
| 新建会话 / SSH 连接 | 终端面板顶部 `＋` |
| 切换模型 | 侧栏底部的模型按钮 |
| 查看审批规则 | 侧栏 → 进阶弹层 |
| 恢复 / 删除历史会话 | 「最近会话」行：点一下先看轨迹，右键可复制 id 或移到废纸篓 |
| 重连 sidecar | 上下文头的 `⚙` |

审批卡会标注命令的目标（本地 / `user@host`）——这是"命令可能发到远程"的唯一可见面。

---

## 配置本地模型（OpenAI 兼容端点）

内置只有 DeepSeek 两个档位，但 CogniTerm 可以挂任意 **OpenAI 兼容端点**：
本地 vLLM / SGLang，或内网推理网关。

**怎么配**

1. Settings →「模型端点（本地部署 / 自定义网关）」→ `添加端点…`
2. 填三样：
   - **Base URL**（带 `/v1`）：`http://10.100.51.218:18507/v1`
   - **路由名**：会变成 dsh 的 provider key，小写字母 / 数字 / 连字符
   - **API Key**：本地无鉴权可以留空（见下面"占位凭据"）
3. 点 **从端点拉取模型列表**：直接问 `/v1/models`，别手抄 id。大小写错一个字母就是
   `UNKNOWN_MODEL`——我们踩过 `qwen3.8-27b` vs `Qwen3.8-27B`。
4. 填上下文窗口（本地 256K 常见值 `262144`）：填大了服务端直接 400，填小了会提前压缩历史。
5. 保存 → **重连 sidecar**。

**用起来**

- **会话内实时切换**：侧栏 → 会话配置 → 模型，新端点会作为独立分组出现，不用重启
- **设为启动默认**：Settings → 默认模型，自定义端点的模型与内置档并列

**它到底怎么实现的**

端点清单存 `~/Library/Application Support/CogniTerm/model-endpoints.json`，启动时渲染成一份
dsh patch 覆盖层传给 `--patch`：

```yaml
- id: llm-pi-ai          # dsh-base 里是休眠挂载：给出 providers 即注册路由
  config:
    providers:
      local-qwen:        # 路由名 = pi-ai 的 provider key
        api: openai-completions
        baseURL: 'http://10.100.51.218:18507/v1'
        apiKeyEnv: COGNITERM_KEY_LOCAL_QWEN
        models: [{ id: 'Qwen3.8-27B', contextWindow: 262144 }]
```

API Key 不进 patch：它存在 Keychain，启动时以同名环境变量注入子进程环境，patch 里只留引用。

**两个真踩过的坑**

- **pi-ai 对无鉴权端点也强制要凭据**。变量缺失时请求直接失败
  `PI_AI_ERROR: No API key for provider: local-qwen`，即使上游根本不看 `Authorization`。
  所以界面留空时 App 注入占位值 `local`。
- **provider 是独立维度，不是拼在 model 里**。dsh-acp 的模型选项 value 是
  `JSON.stringify([provider, model])`；同一个模型名可能来自不同端点，
  所以「默认模型」存的是 `(provider, model)` 二元组。

**验证方式（真跑，不看文档）**

```bash
DSH_COGNITERM_PROVIDER=local-qwen DSH_COGNITERM_MODEL=Qwen3.8-27B \
COGNITERM_KEY_LOCAL_QWEN=local \
dsh headless --patch cogniterm-core.patch.yml --patch user-providers.patch.yml "1+1 等于几？"
# → 1+1 等于 2。
```

去掉 `DSH_COGNITERM_PROVIDER` 会回落到内置 `deepseek-official` 并报
`MISSING_CREDENTIAL`——这一正一负两条输出就是"provider 真的被改了"的判据。

---

## 项目结构

```
App/
├── Sources/
│   ├── Models/       ConversationModel（对话流与工具调用状态）
│   ├── Services/     SidecarService（生命周期 + ACP）/ TerminalMCPServer /
│   │                 SessionManager（多会话 + 命令执行）/ KeychainService
│   └── Views/        主分栏 / 轨迹流 / 审批卡 / 终端面板 / 侧栏 / 设置 / 会话重放
├── Resources/        patches（dsh profile 覆盖层）、Assets、runtime（vendor）
└── Tests/            App 层测试（含 MCP server、会话管理、集成）

Packages/
├── AcpClient/        ACP 协议客户端：JSON-RPC 分帧、会话配置、权限应答
├── TerminalCore/     PTY（含 C shim）、终端 profile、SSH 目标校验
├── PolicyEngine/     命令词法切分、风险标签、审批规则匹配
├── Persistence/      SwiftData 模型（会话、书签、规则）
├── SessionLogReader/ dsh 会话日志（JSONL）解析与重放
└── SwiftTerm/        vendored 终端引擎（上游 + 少量必要修改）

scripts/              build / install / vendor-runtime / fetch-runtime / run-tests
docs/                 设计文档（研究稿，含决策记录）
```

---

## 设计文档

仓库里的 `docs/` 是设计与决策记录，写的是**为什么这样做**，包含被否掉的方案和实证依据：

- [`docs/dsh-as-agentic-core-proposal.md`](docs/dsh-as-agentic-core-proposal.md) — 把 dsh 收编为 agentic core：三条路线对比、profile 裁剪、决策记录
- [`docs/agent-terminal-fusion.md`](docs/agent-terminal-fusion.md) — 两个执行平面的断层分析与缝合方案
- [`docs/terminal-interaction-upgrade.md`](docs/terminal-interaction-upgrade.md) — 终端交互盘点与分层实施
- [`docs/ssh-remote-support-proposal.md`](docs/ssh-remote-support-proposal.md) — SSH 会话的架构接缝与选项注入防线

---

## 已知限制

- **仅 macOS / Apple Silicon**，没有跨平台计划。
- **SSH 只是会话承载**，不含 RDP / VNC / X11 转发。
- **会话级 cwd 不可变更**：dsh 在 `newSession` 时定死工作目录，所以终端里 `cd` 之后 agent 不会跟随——UI 只做提示与一键拉回，不会悄悄改你的上下文。
- **不存任何凭据**：SSH 只保存书签（无密码字段），私钥口令由 `ssh` 自己提示。
- **历史会话是「先看再继续」两步**：dsh 的 `session/resume` 不回放消息，直接 resume 等于恢复一段看不见的上下文。所以列表先读本地轨迹渲染预览，你确认后才在该上下文继续。列表数据也不走 ACP——`session/list` 会裁掉标题与时间，标题取自 dsh 自己写的 projcache，轨迹是 zstd 多帧，由内置 node 逐帧解压。
- **空会话默认不列出**：dsh 每新建一次会话就落一个空目录，实测空目录占比过半（123 个里 69 个），默认折叠，需要时在「查看全部」里打开开关。
- 构建产物是 **ad-hoc 签名**，首次打开需要在「系统设置 → 隐私与安全性」里放行。

---

## License

尚未添加 LICENSE 文件。依赖的上游（[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)、[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)）均为 MIT，本项目与 MIT 兼容的开源协议最为合适——待维护者确定后补充。
