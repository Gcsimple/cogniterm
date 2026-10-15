import Foundation

/// 轻量 shell 词法切分：支持单/双引号、反斜杠转义、环境变量前缀剥离。
/// 不追求成为完整 shell 解析器——只服务于"规则匹配"这一安全用途，
/// 解析不了的复杂命令一律视为不可信、走人工审批。
public enum CommandTokenizer {

    public struct EnvAssignment: Equatable {
        public var key: String
        public var value: String
    }

    public struct Result: Equatable {
        public var tokens: [String]
        public var envAssignments: [EnvAssignment]
        public var hadParseError: Bool
    }

    public static func tokenize(_ command: String) -> Result {
        var tokens: [String] = []
        var envAssignments: [EnvAssignment] = []
        var current = ""
        var hasCurrent = false
        var index = command.startIndex
        var parseError = false

        func push() {
            if hasCurrent {
                tokens.append(current)
                current = ""
                hasCurrent = false
            }
        }

        while index < command.endIndex {
            let ch = command[index]
            switch ch {
            case " ", "\t", "\n":
                push()
            case "'":
                // 单引号：原样读到下一个单引号
                index = command.index(after: index)
                var closed = false
                while index < command.endIndex {
                    if command[index] == "'" { closed = true; break }
                    current.append(command[index])
                    hasCurrent = true
                    index = command.index(after: index)
                }
                if !closed { parseError = true; return Result(tokens: [], envAssignments: [], hadParseError: true) }
            case "\"":
                // 双引号：反斜杠仅转义 \" \\ $ `
                index = command.index(after: index)
                var closed = false
                while index < command.endIndex {
                    let c = command[index]
                    if c == "\\" {
                        let next = command.index(after: index)
                        if next < command.endIndex, "\\\"$`".contains(command[next]) {
                            current.append(command[next])
                            hasCurrent = true
                            index = command.index(after: next)
                            continue
                        }
                        current.append("\\")
                    } else if c == "\"" {
                        closed = true
                        break
                    } else {
                        current.append(c)
                        hasCurrent = true
                    }
                    index = command.index(after: index)
                }
                if !closed { return Result(tokens: [], envAssignments: [], hadParseError: true) }
            case "\\":
                let next = command.index(after: index)
                if next < command.endIndex {
                    current.append(command[next])
                    hasCurrent = true
                    index = next
                }
            case ";", "|", "&", "(", ")", "<", ">", "`", "$":
                // 复合命令 / 命令替换 / 重定向：规则引擎不做安全承诺。
                return Result(tokens: [], envAssignments: [], hadParseError: true)
            default:
                current.append(ch)
                hasCurrent = true
            }
            index = command.index(after: index)
        }
        push()

        // 剥离前导 VAR=value（只对形如 KEY=VALUE 的整 token 生效）。
        while let first = tokens.first, let assignment = parseEnvAssignment(first) {
            envAssignments.append(assignment)
            tokens.removeFirst()
        }

        return Result(tokens: tokens, envAssignments: envAssignments, hadParseError: parseError)
    }

    /// 归一化用于规则比对：去掉 env 前缀、空白折叠、路径 . 段保留。
    public static func normalize(_ command: String) -> [String] {
        tokenize(command).tokens
    }

    private static func parseEnvAssignment(_ token: String) -> EnvAssignment? {
        guard let equal = token.firstIndex(of: "=") else { return nil }
        let key = String(token[..<equal])
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              key.first?.isLetter == true || key.first == "_" else { return nil }
        return EnvAssignment(key: key, value: String(token[token.index(after: equal)...]))
    }
}
