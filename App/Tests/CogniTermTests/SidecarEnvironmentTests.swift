import XCTest
@testable import CogniTerm

/// sidecar 启动环境的代理剔除回归。
///
/// 背景（2026-10-16 实测复现）：App 全量继承 `ProcessInfo.processInfo.environment`，
/// 而启动 App 的进程常带着**临时 loopback 代理**（本机开发环境每次工具调用注入
/// `HTTP(S)_PROXY=http://127.0.0.1:<临时端口>`，端口归该次调用所有、调用结束即消失）。
/// dsh 把这些变量当"请求走哪条路"的依据，于是：
///   死端口 → connect ECONNREFUSED（约 10ms，请求没出机器）
///   → dsh-llm 归类 TRANSPORT → 退避重试 5 次全挂 → turn/end error
///   → ACP 返回 -32603（Internal error），用户侧只看到一句看不懂的 "prompt 失败"。
///
/// 对照实验（同一探针、同一 runtime，唯一变量是这几个环境变量）：
///   带死代理 → "DeepSeek Messages transport failed"
///   剔除代理 → 正常拿到 DeepSeek HTTP 应答。
@MainActor
final class SidecarEnvironmentTests: XCTestCase {

    /// 九类代理变量必须全部剔除（大小写两套 + undici 开关）。
    func testStripsAllProxyVariables() {
        let service = SidecarService.shared
        var environment: [String: String] = [
            "HTTP_PROXY": "http://127.0.0.1:61920",
            "HTTPS_PROXY": "http://127.0.0.1:61920",
            "http_proxy": "http://127.0.0.1:61920",
            "https_proxy": "http://127.0.0.1:61920",
            "ALL_PROXY": "socks5://127.0.0.1:1080",
            "all_proxy": "socks5://127.0.0.1:1080",
            "NO_PROXY": "localhost,127.0.0.1",
            "no_proxy": "localhost,127.0.0.1",
            "NODE_USE_ENV_PROXY": "1",
            // 这些必须原样保留。
            "DEEPSEEK_API_KEY": "sk-keep-me",
            "DSH_PERMISSION_MODE": "workspace-write",
            "DSH_COGNITERM_MODEL": "deepseek-flash",
            "PATH": "/usr/bin",
        ]

        service.stripProxyEnvironment(&environment)

        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                     "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                     "NODE_USE_ENV_PROXY"] {
            XCTAssertNil(environment[name], "\(name) 必须被剔除，否则 sidecar 会走一条可能已失效的代理")
        }
        // 非代理变量一个都不能动。
        XCTAssertEqual(environment["DEEPSEEK_API_KEY"], "sk-keep-me")
        XCTAssertEqual(environment["DSH_PERMISSION_MODE"], "workspace-write")
        XCTAssertEqual(environment["DSH_COGNITERM_MODEL"], "deepseek-flash")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    /// 没有代理变量时应当是彻底的 no-op（不报错、不改动任何键）。
    func testNoProxyVariablesIsNoOp() {
        let service = SidecarService.shared
        var environment: [String: String] = [
            "DEEPSEEK_API_KEY": "sk-x",
            "DSH_HOME": "/tmp/dsh-home",
        ]
        let before = environment

        service.stripProxyEnvironment(&environment)

        XCTAssertEqual(environment, before)
    }

    /// 剔除必须留下诊断记录——静默改环境是这类故障最难排查的原因。
    func testStrippingIsRecordedInDiagnostics() {
        let service = SidecarService.shared
        service.diagnostics.removeAll()
        var environment: [String: String] = ["HTTPS_PROXY": "http://127.0.0.1:61920"]

        service.stripProxyEnvironment(&environment)

        XCTAssertTrue(service.diagnostics.contains { $0.contains("HTTPS_PROXY") },
                      "剔除代理变量必须写入 diagnostics，不能静默")
    }

    // MARK: - 沙箱 profile 与注入参数的一致性

    /// 从本文件位置反推仓库内源文件（与 CoreProfilePatchTests.patchText 同一套做法）。
    private func repoFile(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CogniTermTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // App
            .appendingPathComponent(relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "找不到：\(url.path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func capturedGroups(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// 剥掉 SBPL 的行内注释（`;` 到行尾）。
    ///
    /// 扫 sb 规则前**必须先剥注释**：这个文件用大段注释记录踩坑经过，注释里会出现
    /// `(remote ...)` / `(param "X")` 这类字样，不剥就会把说明文字当成规则本体
    /// —— 实测踩到：注释里写 `(param "X")` 举例，`testEverySandboxParamIsInjected`
    /// 立刻把它当成"sb 用了但没注入的参数 X"报失败。
    private func sbplWithoutComments(_ sb: String) -> String {
        sb.split(separator: "\n")
            .map { $0.prefix { $0 != ";" } }
            .joined(separator: "\n")
    }

    /// 2026-10-16 装到 /Applications 后踩到的最贵一次。
    ///
    /// sidecar.sb 的只读放行里只有 `(subpath (param "RUNTIME_DIR"))`，而 dsh 的
    /// `--patch <path>` 文件位于 `Contents/Resources` **根**，不在 `runtime/` 之下。
    /// 开发期 app 落在 `$HOME` 内（`.build/…`），会被 `(subpath HOME_DIR)` 的读放行
    /// 顺带覆盖，所以本地怎么测都正常；一旦装到 `/Applications`（既不在 `$HOME`、
    /// 也不在 `/private/tmp`），**两条放行都不覆盖它** → 沙箱内的 dsh 读不到
    /// `--patch` → 启动即失败 → sidecar 反复崩溃重启，而 App 侧只显示
    /// "sidecar 连续崩溃"，完全看不出是沙箱路径问题。
    ///
    /// 对照实验（同一份二进制，唯一变量 = 位置）：
    ///   `.build/…`（$HOME 下）      → sidecar 正常
    ///   `/tmp/…`（/private/tmp 下） → sidecar 正常
    ///   `/Applications/…`           → sidecar 起不来
    func testSandboxProfileGrantsReadToAppBundle() throws {
        let sb = try repoFile("Resources/sandbox/sidecar.sb")
        XCTAssertTrue(sb.contains("(subpath (param \"APP_BUNDLE\"))"),
                      "sidecar.sb 必须放行 app bundle 自身：--patch 在 Contents/Resources 根，"
                      + "不在 RUNTIME_DIR 之下；装到 /Applications 后不覆盖它 sidecar 就起不来")
    }

    /// sb 里用到的每个 `(param "X")` 都必须由 SidecarService 注入。
    ///
    /// 漏注入时 `sandbox-exec` 会因未知参数直接失败，sidecar 起不来，而 App 侧
    /// 只有一句"连续崩溃"。这条断言把它变成测试期就能看见的错误——比真启动一次
    /// 才发现便宜得多。
    ///
    /// **两个 profile 都要覆盖**（2026-10-17 起按沙箱模式二选一）：
    /// sidecar.sb（confined，read-only 档）+ sidecar-writable.sb（HOME 全量写，
    /// workspace-write / 关闭档）。writable 档是 confined 档的副本加一条 HOME
    /// 写放行，参数集相同——漏给任何一个文件加 param 都会在这里现形。
    func testEverySandboxParamIsInjected() throws {
        let source = try repoFile("Sources/Services/SidecarService.swift")
        let injected = Set(capturedGroups(in: source, pattern: #""-D", "([A-Z_]+)="#))

        XCTAssertFalse(injected.isEmpty, "解析不到任何 -D 注入，说明正则或注入写法变了，本断言已失效")
        for profile in ["Resources/sandbox/sidecar.sb",
                        "Resources/sandbox/sidecar-writable.sb"] {
            let sb = sbplWithoutComments(try repoFile(profile))
            let used = Set(capturedGroups(in: sb, pattern: #"\(param "([A-Z_]+)""#))
            XCTAssertFalse(used.isEmpty, "\(profile) 解析不到任何 (param ...)，说明正则或文件结构变了，本断言已失效")
            let missing = used.subtracting(injected)
            XCTAssertTrue(missing.isEmpty,
                          "\(profile) 用到但 SidecarService 没有注入的 -D 参数：\(missing.sorted())")
        }
    }

    // MARK: - 沙箱模式 → profile 映射（2026-10-17 双档墙）

    /// 纯函数映射：read-only → confined 档；workspace-write / 关闭 → writable 档。
    ///
    /// 反了就是事故：read-only 档位给了 HOME 全量写 = 「只读」名不副实；
    /// workspace-write 档位用 confined = escalation 审批批了也白批
    /// （静态单根墙跟不动内层逐次决策，2026-10-17 实证）。
    func testSandboxProfileNameMapping() {
        XCTAssertEqual(SidecarService.sandboxProfileName(for: .readOnly), "sidecar.sb")
        XCTAssertEqual(SidecarService.sandboxProfileName(for: .workspaceWrite), "sidecar-writable.sb")
        XCTAssertEqual(SidecarService.sandboxProfileName(for: .off), "sidecar-writable.sb")
    }

    /// writable 档必须真的放开 HOME 写，且**凭据墙一条都不能少**。
    ///
    /// 这条放行是「escalation 审批能落地」的前提：dsh 内层批准写工作区外路径后，
    /// 外层墙再 EPERM 的话用户点「允许」毫无意义。而凭据墙（.ssh / .gnupg /
    /// Keychains / .aws / .netrc）是安全底线，SBPL 里 deny 优先于 allow。
    func testWritableProfileGrantsHomeWriteButKeepsCredentialWall() throws {
        let code = sbplWithoutComments(try repoFile("Resources/sandbox/sidecar-writable.sb"))

        XCTAssertTrue(code.contains("(allow file-write* file-ioctl\n       (subpath (param \"HOME_DIR\")))"),
                      "writable 档必须放开 HOME 写，否则内层 escalation 审批通过也会被外层 EPERM")
        for anchor in ["HOME_SSH", "HOME_GNUPG", "HOME_KEYCHAINS", "AWS_CREDS", "NETRC"] {
            XCTAssertTrue(code.contains("(param \"\(anchor)\")"),
                          "writable 档的凭据墙缺少 \(anchor)：放开 HOME 写时凭据必须仍然 deny")
        }
        // 网络块与 confined 档同规矩：不带 (remote ...) 过滤器。
        XCTAssertTrue(code.contains("(allow network-outbound)"), "writable 档必须放行出站（本机过滤器失效，见 confined 档注释）")
        XCTAssertFalse(code.contains("(remote "), "writable 档同样不能带 (remote ...) 过滤器")
        // app bundle 放行不能丢（--patch 在 Contents/Resources 根）。
        XCTAssertTrue(code.contains("(subpath (param \"APP_BUNDLE\"))"),
                      "writable 档必须放行 app bundle 自身，否则装到 /Applications 后读不到 --patch")
    }

    // MARK: - 默认工作区（2026-10-17：$HOME → ~/CogniTerm）

    /// 默认工作区必须落在 $HOME 下一个可见的、App 自己的目录里。
    ///
    /// 旧默认值 = 整个 $HOME 的实证故障：dsh 的 glob 用 `--no-ignore --hidden`
    /// 全量遍历工作区，扫 home 必撞 macOS TCC（`~/Library/Containers/*` →
    /// `Operation not permitted`）且必然 30s 超时——5 个会话 4 次手动中止。
    func testDefaultWorkspaceIsNotHomeItself() {
        let url = SidecarService.defaultWorkspaceURL()
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertNotEqual(url.standardizedFileURL.path, home.standardizedFileURL.path,
                          "默认工作区不能是 $HOME 本身：glob 全量遍历 home 必炸（TCC + 超时）")
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path),
                      "默认工作区应该在 $HOME 之下（Finder 可见、TCC 无需额外授权）")
        XCTAssertEqual(url.lastPathComponent, "CogniTerm")
    }

    /// ⛔ `network-outbound` 不得写 `(remote ...)` 过滤器。
    ///
    /// 背景（2026-10-16 "发消息必报错"的真因，全链路已确证）：
    /// 本机 macOS 27.0.1 上**带过滤器的 `network-outbound` 一条都不放行**，等价于
    /// 把网络整个禁掉。单变量矩阵（最小 profile 只换网络块，同环境同二进制）：
    ///   `(remote tcp "*:443") (remote udp "*:53")`   → FAIL
    ///   `(remote tcp "*:*")   (remote udp "*:*")`    → FAIL（不是端口问题）
    ///   `(remote ip  "*:443") (remote ip  "*:53")`   → FAIL（不是协议关键字问题）
    ///   `(allow network-outbound)`（无过滤器）        → HTTP 401 ✅
    ///
    /// 后果链条：沙箱内 `getaddrinfo` 立刻失败 → node `fetch` 抛
    /// `TypeError: fetch failed` / cause `ENOTFOUND` → dsh-llm-deepseek 包成
    /// `LlmError("...transport failed", "TRANSPORT", { cause })`，而 **cause 既不写
    /// 会话 JSONL 也不打 stderr** → ACP 只回 `-32603`，App 里就是一句看不懂的
    /// "transport failed"，且 34ms 就失败（不是超时，是立刻被拒）。
    ///
    /// 这条断言只是**防回归重写**；真正的验证是 `scripts/probe-sandbox-network.sh`
    /// （用 LaunchServices 派生的小 .app 当宿主，绕过开发环境的 Agent 沙箱，真实应用 seatbelt）。
    func testSandboxNetworkRulesDoNotUseRemoteFilters() throws {
        let sb = try repoFile("Resources/sandbox/sidecar.sb")
        // 去掉行内注释：本文件的网络块里用大段注释记录了这段踩坑，注释里当然会出现
        // "(remote ...)" 字样，不能把它当成规则本体。
        let code = sbplWithoutComments(sb)

        XCTAssertTrue(code.contains("(allow network-outbound)"),
                      "sidecar.sb 必须有**不带过滤器**的 (allow network-outbound)，"
                      + "否则沙箱内 DNS 立刻失败、prompt 必报 TRANSPORT")
        XCTAssertFalse(code.contains("(remote "),
                       "sidecar.sb 的 network-outbound 不能带 (remote ...) 过滤器："
                       + "本机 macOS 实测带过滤器的写法一条都不放行（等于禁网）。"
                       + "详见本测试与 scripts/probe-sandbox-network.sh 的说明")
    }
}
