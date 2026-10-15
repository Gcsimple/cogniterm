import Foundation

/// "始终允许"规则（由审批卡沉淀，仅用于 App 端 ACP 自动应答；不改变 dsh 一次性审批语义）。
public struct ApprovalRule: Codable, Sendable, Equatable {
    public var id: UUID
    public var tool: String            // bash / edit ...
    /// 命令模板，支持 * 与 ? 通配，按 token 比较（如 "git status *"）。
    public var pattern: String
    public var workspaceScoped: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(),
                tool: String,
                pattern: String,
                workspaceScoped: Bool = true,
                createdAt: Date = Date()) {
        self.id = id
        self.tool = tool
        self.pattern = pattern
        self.workspaceScoped = workspaceScoped
        self.createdAt = createdAt
    }
}

public struct CommandInvocation: Sendable, Equatable {
    public var tool: String
    public var command: String
    /// 命令工作目录绝对路径。
    public var cwd: String?
    /// 当前工作区根目录（workspaceScoped 规则要求 cwd 在其下）。
    public var workspaceRoot: String?

    public init(tool: String, command: String, cwd: String? = nil, workspaceRoot: String? = nil) {
        self.tool = tool
        self.command = command
        self.cwd = cwd
        self.workspaceRoot = workspaceRoot
    }
}

/// 规则匹配器：模板与命令逐 token 通配比较；解析失败/复合命令一律不匹配（fail-closed）。
public struct RuleSet: Equatable {
    public var rules: [ApprovalRule]

    public init(rules: [ApprovalRule] = []) {
        self.rules = rules
    }

    public func automaticAllow(for invocation: CommandInvocation) -> ApprovalRule? {
        let parsed = CommandTokenizer.tokenize(invocation.command)
        guard !parsed.hadParseError, !parsed.tokens.isEmpty else { return nil }

        for rule in rules where rule.tool == invocation.tool {
            if rule.workspaceScoped, !RuleSet.isInsideWorkspace(cwd: invocation.cwd,
                                                       root: invocation.workspaceRoot) {
                continue
            }
            let patternTokens = CommandTokenizer.normalize(rule.pattern)
            guard !patternTokens.isEmpty else { continue }
            if RuleSet.matches(patternTokens: patternTokens, commandTokens: parsed.tokens) {
                return rule
            }
        }
        return nil
    }

    /// 逐 token 匹配：只有模板最后一个 token 允许是 `*`，此时可覆盖命令剩余的一个或多个
    /// token（`npm test *` 能匹配 `npm test -- --x`）。非通配位置必须严格一致，
    /// 因此 `git status` 永远匹配不到 `git push`。
    static func matches(patternTokens: [String], commandTokens: [String]) -> Bool {
        if patternTokens.last == "*" {
            let fixed = patternTokens.dropLast()
            guard commandTokens.count >= fixed.count + 1 else { return false }
            return zip(fixed, commandTokens.prefix(fixed.count))
                .allSatisfy { wildcardMatch(pattern: $0, text: $1) }
        }
        guard patternTokens.count == commandTokens.count else { return false }
        return zip(patternTokens, commandTokens)
            .allSatisfy { wildcardMatch(pattern: $0, text: $1) }
    }

    /// 仅 * 与 ? 的 glob，锚定整段 token。
    static func wildcardMatch(pattern: String, text: String) -> Bool {
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += "[^\\s]*"
            case "?": regex += "."
            case "\\", ".", "(", ")", "+", "[", "]", "{", "}", "^", "$", "|", "/":
                regex.append("\\")
                regex.append(ch)
            default:
                regex.append(ch)
            }
        }
        regex += "$"
        guard let expression = try? NSRegularExpression(pattern: regex) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private static func isInsideWorkspace(cwd: String?, root: String?) -> Bool {
        guard let cwd, let root else { return false }
        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.path
        return cwdURL == rootURL || cwdURL.hasPrefix(rootURL.hasSuffix("/") ? rootURL : rootURL + "/")
    }
}
