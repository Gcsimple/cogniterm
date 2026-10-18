import XCTest
import Persistence
@testable import CogniTerm

/// agentic core 覆盖层的结构性护栏。
///
/// 这些断言针对 `App/Resources/patches/cogniterm-core.patch.yml` 的**文本内容**，
/// 目的不是验证 yml 语义（那要真跑 dsh），而是防止后续改动把「不可被裁剪的
/// 核心能力」误写进裁剪清单。真跑一遍的验证在 scripts/dump-profile.sh 里。
final class CoreProfilePatchTests: XCTestCase {

    /// 回归：打包后必须能从 app bundle 的 Resources 里**解析到**收编 patch。
    ///
    /// 2026-10-16 的真实事故：`Bundle.url(forResource: "cogniterm-core",
    /// withExtension: "yml")` 把**最后一个 `.` 之后**当扩展名，于是去找
    /// `cogniterm-core.patch` + `yml`——而实际文件名是 `cogniterm-core.patch.yml`
    /// → **永远返回 nil**（同目录的 `no-telemetry.yml` 正常命中，所以看起来"只是
    /// 那一个文件的问题"）。App 因此一直走
    /// 「未找到 cogniterm-core.patch.yml，以 dsh 默认 profile 启动」的降级分支，
    /// 收编策略（身份提示词、审批/沙箱语义对齐、能力裁剪、模型绑定）全部静默失效。
    ///
    /// 关键在于：**"文件在不在 bundle 里"的检查全都通过**（文件确实在），
    /// 坏的是"能不能按名字找到"。所以断言必须落在解析结果上，不是存在性上。
    func testCorePatchFileResolvesFromAppBundleResources() throws {
        XCTAssertEqual(SidecarService.corePatchFileName, "cogniterm-core.patch.yml",
                       "常量必须含 .patch 段，且与 App/Resources/patches/ 下的源文件同名")

        // <App>.app/Contents/PlugIns/CogniTermTests.xctest → 连退三级到 <App>.app
        let app = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // <App>.app
        // 这里刻意用 XCTFail 而不是 XCTSkip：静默跳过会让这条回归防护形同虚设，
        // 而 scripts/run-tests.sh 的流程永远是 app 宿主布局，走不到这个分支。
        guard app.pathExtension == "app" else {
            return XCTFail("不是在 app 宿主布局下运行，本回归防护失效：\(app.path)")
        }
        let resources = app.appendingPathComponent("Contents/Resources")

        XCTAssertNotNil(
            SidecarService.patchURL(named: SidecarService.corePatchFileName, in: resources),
            "app bundle 里必须能按完整文件名解析到 \(SidecarService.corePatchFileName)：\(resources.path)")
        XCTAssertNotNil(
            SidecarService.patchURL(named: "no-telemetry.yml", in: resources),
            "隐私补丁同样必须可解析")

        // 反例固化：这正是当初踩的坑，用 Bundle 的 resource/extension 语义永远找不到。
        XCTAssertNil(
            Bundle(path: app.path)?.url(forResource: "cogniterm-core", withExtension: "yml"),
            "Bundle.url(forResource:withExtension:) 把最后一个点之后当扩展名，找不到 *.patch.yml；"
            + "若哪天它开始能命中了，说明命名或打包方式变了，需要重新审视本断言")
    }

    /// 收编策略的唯一真相源。
    private func patchText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CogniTermTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // App
            .appendingPathComponent("Resources/patches/cogniterm-core.patch.yml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "找不到收编 patch：\(url.path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 从 patch 文本里取出所有 `- id: X ... disabled: true` 的 id。
    private func disabledIDs(in text: String) -> Set<String> {
        var result: Set<String> = []
        var pending: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // 只看顶层条目（无缩进的 "- id:"），config: 子层不参与。
            if line.hasPrefix("- id: ") {
                pending = String(line.dropFirst("- id: ".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if let id = pending,
                      line.hasPrefix("  disabled: true") {
                result.insert(id)
                pending = nil
            } else if line.hasPrefix("- ") {
                pending = nil
            }
        }
        return result
    }

    /// 核心能力：agent loop、工具注册、ACP 出口、会话持久化、沙箱与审批、
    /// skill、token 计量、上下文压缩。这些一旦被裁，App 直接不可用。
    func testDoesNotDisableCoreCapabilities() throws {
        let disabled = disabledIDs(in: try patchText())
        let mustStay = [
            "agent-loop",       // agent 主循环
            "tools",            // 工具注册中心
            "system-prompt",    // 提示词装配
            "llm-deepseek",     // DeepSeek 模型接入
            "acp-app-startup",  // ACP 出口（App 唯一的对接面）
            "session",          // 会话状态
            "session-persistence-jsonl", // 会话落盘（历史/恢复）
            "sandbox",          // 内层沙箱执行面
            "sandbox-policy",   // 沙箱模式开关
            "approval",         // 审批链路
            "permission",       // 权限预设
            "tool-fs",          // 文件读写工具（App 的 fs/read_text_file 对面）
            "skill",            // 技能系统（差异化能力）
            "tool-skill",       // 技能调用工具
            "token-meter",      // usage 上报（ComposerView 的 token 展示依赖）
            "compaction-basic", // 上下文压缩
        ]
        for id in mustStay where disabled.contains(id) {
            XCTFail("收编 patch 误关了核心能力：\(id)")
        }
    }

    /// 默认必须关掉的能力：联网检索、子代理编排、会话日志上报。
    /// 这三条是产品边界，不是优化项——放开要改产品定义，不是改这个文件。
    func testDisablesNetworkAndTelemetryByDefault() throws {
        let disabled = disabledIDs(in: try patchText())
        for id in ["web", "tool-web", "web-search-deepseek", "web-fetch-http",
                   "subagent", "tool-subagent-control", "tool-subagent-fork",
                   "tool-workflow", "session-log-deepseek"] {
            XCTAssertTrue(disabled.contains(id), "应当默认关闭：\(id)")
        }
    }

    /// dsh 自己那套 bash 工具必须关掉：它走 dsh 内部 sandbox，
    /// 会和 App 的审批卡抢审批语义（两边都认为自己该管）。
    func testDisablesDshoOwnedBashTool() throws {
        let disabled = disabledIDs(in: try patchText())
        XCTAssertTrue(disabled.contains("tool-bash"),
                      "dsh 的 tool-bash 必须关闭，避免与 App 审批卡语义冲突")
        XCTAssertTrue(disabled.contains("bash-sandbox"))
    }

    /// 审批策略必须显式绑定 DSH_PERMISSION_MODE，不能依赖 dsh 默认值。
    /// SidecarService.start() 注入该环境变量，两层沙箱与审批共用一个开关。
    ///
    /// ⚠️ 这条断言防的是一个真实回归：`policy` 曾经漏了 `!!js` 前缀，YAML 解析
    /// 照样成功、`--dump-config` 照样显示 enabled，但 dsh 拿字面量去过 schema
    /// （"ask" | "never"）→ ValidationError → approval 插件整个不激活，
    /// 连带 permission 也 pending。只有真启动才会在 stderr 暴露。
    func testApprovalPolicyBindsToPermissionMode() throws {
        let text = try patchText()
        XCTAssertTrue(text.contains("DSH_PERMISSION_MODE"),
                      "审批策略必须显式绑定 DSH_PERMISSION_MODE")
        XCTAssertTrue(text.contains("- id: approval"))
        XCTAssertTrue(text.contains("- id: sandbox-policy"))
        // policy 必须是 !!js 表达式节点，不能是普通字符串。
        XCTAssertTrue(text.contains("policy: !!js"),
                      "approval.policy 必须带 !!js 前缀，否则表达式会被当字面量送去过 schema 而激活失败")
        // 表达式含三元，必须用折叠块标量；单行 plain 会被 ` : ` 切成嵌套 mapping。
        XCTAssertTrue(text.contains("policy: !!js >-"),
                      "含 ` : ` 的三元表达式必须用 !!js >- 折叠标量，单行 plain 会报 Nested mappings")
    }

    /// YAML 缩进错误会让 dsh 在启动期直接抛 "failed to parse overlay"，
    /// 这里做一次最轻量的结构自检（真实验证用 scripts/dump-profile.sh）。
    func testPatchHasNoMalformedListEntries() throws {
        for (index, rawLine) in try patchText().split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            // "- id foo"（缺冒号）会触发 YAMLException: bad indentation of a sequence entry
            if line.hasPrefix("- id ") {
                XCTFail("第 \(index + 1) 行缺冒号（`- id ` 应为 `- id: `）：\(line)")
            }
        }
    }

    /// 默认模型必须走 `!!js process.env.DSH_COGNITERM_MODEL`，且必须带回落值。
    ///
    /// 这条断言的价值在于「不依赖 App 侧注入」：sidecar 永远会被注入该变量，
    /// 但一旦回落值被删掉，App 启动早期（Keychain 尚未就绪、诊断日志、离线 dump）
    /// 就会拿到 undefined，dsh 侧表现为 provider 路由失败而不是安静回落——
    /// 那是最难排查的一类故障。
    ///
    /// 为什么必须绑**两处**（2026-10-16 的实证）：
    ///   - `acp` 行才是 CogniTerm 会话模型的真控制点。dsh-acp 不消费
    ///     agentDefaultModel（消费者只有 dsh-api-session-controller / dsh-webhook /
    ///     dsh-headless / dsh-tool-cordis）；其 README 明写 "Every session the
    ///     server creates uses the provider and model configured here"。
    ///     只绑 agent-default-model 时，27 个会话日志里
    ///     request/header.config.model 恒为 acp 行的值，设置页的选择器完全无效。
    ///   - `agent-default-model` 一并绑定是为了别的入口（HTTP / webhook /
    ///     headless）被启用时口径一致。
    func testModelBindsToEnvAtBothEntries() throws {
        let text = try patchText()
        let binding = "!!js process.env.DSH_COGNITERM_MODEL"
        XCTAssertEqual(text.components(separatedBy: binding).count - 1, 2,
                       "模型绑定应恰好出现 2 处：agent-default-model 与 acp")
        XCTAssertTrue(text.contains("- id: agent-default-model\n"))
        XCTAssertTrue(text.contains("- id: acp\n"),
                      "acp 行才是 ACP 会话模型的控制点，漏了它就是空操作")

        // 回落值不从字面量断言，而是**与 Persistence 的枚举取同一个事实源**：
        // 过去两处各写一份字面量，改成目录规范 id 时就得记住同时改两处，
        // 漏一处就出现"设置页选 flash、离线回落用另一个 id"的分裂。
        let fallback = "|| '\(AgentModel.flash.rawValue)'"
        XCTAssertEqual(text.components(separatedBy: fallback).count - 1, 2,
                       "两处绑定都必须回落到 AgentModel.flash.rawValue（\(AgentModel.flash.rawValue)）")
        XCTAssertFalse(text.contains("model: \(AgentModel.flash.rawValue)\n"),
                       "模型不能写死，否则设置页的选择器将完全失效")
    }

    /// `- id: acp` 覆盖时必须同时写回 provider。
    ///
    /// patch 的语义是**整体替换**该条目的 config，不是深合并——已用 `--dump-config`
    /// 实测：写一份只含 `model:` 的 patch，dump 出来的 acp 条目里 provider 直接消失。
    /// provider 一旦为空，会话无法解析路由。这条断言把「必须成对写」钉死。
    func testAcpOverrideReplacesWholeConfigSoProviderMustBeRestated() throws {
        let text = try patchText()
        let blocks = text.components(separatedBy: "\n- ")
        guard let acp = blocks.first(where: { $0.hasPrefix("id: acp\n") }) else {
            return XCTFail("patch 里必须显式覆盖 acp 行（ACP 会话模型的控制点）")
        }
        XCTAssertTrue(acp.contains("provider: deepseek-official"),
                      "patch 整体替换 config，必须同时写回 provider，否则路由解析失败")
        XCTAssertTrue(acp.contains("model: !!js process.env.DSH_COGNITERM_MODEL || '\(AgentModel.flash.rawValue)'"))
    }

    /// patch 里的 provider 必须与模型选择器共存：模型是用户偏好，
    /// provider 是 vendored runtime 的事实（只有 deepseek-official 一家）。
    func testProviderStaysPinnedWhileModelIsVariable() throws {
        let text = try patchText()
        XCTAssertTrue(text.contains("provider: deepseek-official"),
                      "provider 应保持固定：runtime 只内置了 DeepSeek 一家")
    }
}