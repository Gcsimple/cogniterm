import Foundation

public struct RiskTags: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let writesFiles     = RiskTags(rawValue: 1 << 0)
    public static let deletes         = RiskTags(rawValue: 1 << 1)
    public static let network         = RiskTags(rawValue: 1 << 2)
    public static let packageInstall  = RiskTags(rawValue: 1 << 3)
    public static let privilegeEscalation = RiskTags(rawValue: 1 << 4)
    public static let outboundVCS     = RiskTags(rawValue: 1 << 5)
    public static let outsideWorkspace = RiskTags(rawValue: 1 << 6)
    public static let compoundOrUnparseable = RiskTags(rawValue: 1 << 7)

    public var isReadOnly: Bool {
        // 纯读：没有除 outsideWorkspace/compound 之外的任何活动标签。
        let active: RiskTags = [.writesFiles, .deletes, .network, .packageInstall,
                                .privilegeEscalation, .outboundVCS]
        return intersection(active).isEmpty
    }
}

public struct RiskAssessment: Sendable, Equatable {
    public var tags: RiskTags
    public var needsHumanApproval: Bool
    public var reasons: [String]
}

/// 命令风险评级：用于审批卡风险标签展示，以及"严格模式只读自动放行"清单的反向校验。
public enum RiskEvaluator {

    private static let networkCommands: Set<String> = [
        "curl", "wget", "nc", "ncat", "ssh", "scp", "sftp", "rsync", "ping", "telnet",
    ]
    private static let deleteCommands: Set<String> = ["rm", "rmdir", "unlink"]
    private static let writeCommands: Set<String> = [
        "mkdir", "touch", "mv", "cp", "tee", "chmod", "chown", "ln", "dd", "cat",
    ]
    private static let packageInstallPairs: Set<String> = [
        "npm install", "npm i", "pnpm add", "yarn add", "bun add",
        "pip install", "pip3 install", "brew install", "gem install",
    ]

    public static func assess(_ invocation: CommandInvocation) -> RiskAssessment {
        let parsed = CommandTokenizer.tokenize(invocation.command)
        var tags: RiskTags = []
        var reasons: [String] = []

        if parsed.hadParseError {
            tags.insert(.compoundOrUnparseable)
            reasons.append("复合命令或无法解析，必须人工确认")
        }

        let tokens = parsed.tokens
        if let first = tokens.first {
            if first == "sudo" {
                tags.insert(.privilegeEscalation)
                reasons.append("使用 sudo 提权")
            }
            if deleteCommands.contains(first) {
                tags.insert(.deletes)
                tags.insert(.writesFiles)
                reasons.append("删除操作")
            }
            if writeCommands.contains(first) {
                tags.insert(.writesFiles)
                reasons.append("文件写操作")
            }
            if networkCommands.contains(first) {
                tags.insert(.network)
                reasons.append("网络访问")
            }
            if first == "git", tokens.dropFirst().first == "push" {
                tags.insert(.outboundVCS)
                tags.insert(.network)
                reasons.append("git push 外发代码")
            }
            let prefix = tokens.prefix(3).joined(separator: " ")
            if packageInstallPairs.contains(where: { prefix == $0 || prefix.hasPrefix($0 + " ") }) {
                tags.insert(.packageInstall)
                reasons.append("安装依赖包")
            }
        }

        // 路径越界检查：参数中任何绝对路径不在 workspaceRoot 下。
        if let root = invocation.workspaceRoot {
            let outside = tokens.dropFirst().contains { token in
                isAbsolutePath(token) && !isInside(token, root: root)
            }
            if outside {
                tags.insert(.outsideWorkspace)
                reasons.append("访问工作区之外的路径")
            }
        }

        let needsApproval = !tags.isReadOnly || tags.contains(.compoundOrUnparseable)
        return RiskAssessment(tags: tags,
                              needsHumanApproval: needsApproval,
                              reasons: reasons)
    }

    private static func isAbsolutePath(_ token: String) -> Bool {
        (token.hasPrefix("/") || token.hasPrefix("~")) && !token.hasPrefix("//")
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let pathURL = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.path
        return pathURL == rootURL || pathURL.hasPrefix(rootURL + "/")
    }
}
