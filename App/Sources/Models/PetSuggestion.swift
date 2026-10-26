//
//  PetSuggestion.swift
//  CogniTerm
//
//  终端宠物给出的候选项与打分规则。**纯函数、无 IO**：目录列表由调用方
//  预先取好传进来，测试才能不碰文件系统就给全覆盖。
//

import Foundation

struct PetSuggestion: Identifiable, Equatable {
    enum Source: Hashable {
        /// 用户自己跑过的命令（`~/.zsh_history`）。
        case history
        /// 当前目录里的文件 / 子目录。
        case path
        /// 刚才对话里出现过的命令（agent 给的代码块）。
        case agent

        var label: String {
            switch self {
            case .history: return "历史"
            case .path: return "路径"
            case .agent: return "对话"
            }
        }
    }

    /// 稳定标识：同一行命令只该出现一次。
    let id: String
    /// 接受后终端里的**整行内容**（不是插入片段）。
    let command: String
    let source: Source
    /// 会改文件 / 联网 / 提权的命令，气泡里标红，点击后仍要二次确认。
    let isRisky: Bool
}

/// 打分：数值越大越靠前。集中放在一处，改排序不用翻逻辑。
private enum Score {
    static let wholeLineHistory = 100
    static let wholeLineAgent = 90
    static let tokenHistory = 80
    static let tokenAgent = 70
    static let tokenPath = 60
    /// 空行时「最常用」压过「刚聊到的」：输入法的手感来自频次，
    /// 频率最高的那条一旦排到第二，宠物就会显得比人还善变。
    static let frequentHistory = 40
    static let recentAgent = 20
}

enum PetSuggestionEngine {

    /// - Parameters:
    ///   - entries: `cwd` 下的条目名，目录已带尾部 `/`（由调用方补齐，
    ///     这样引擎不必再问文件系统一次）。
    ///   - history: 旧 → 新排列的命令历史。
    static func suggest(
        line: String,
        leadingContext: String,
        token: String,
        kind: PetInputBuffer.Confidence,
        entries: [String],
        history: [String],
        agentCommands: [String],
        limit: Int = 5
    ) -> [PetSuggestion] {
        var best: [String: (score: Int, order: Int, suggestion: PetSuggestion)] = [:]
        var counter = 0

        func offer(_ command: String, score: Int, source: PetSuggestion.Source) {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != line else { return }
            counter += 1
            if let existing = best[trimmed], existing.score >= score { return }
            best[trimmed] = (score, counter, PetSuggestion(id: trimmed, command: trimmed, source: source, isRisky: false))
        }

        let stale = !kind.isExact

        if token.isEmpty {
            // 行是空的：给「最常用」，再**留一个位置**给「刚聊到的」——
            // 否则历史一多，agent 说的那条永远挤不进前五，这条数据线就白接了。
            for command in frequentCommands(history, limit: max(1, limit - 1)) {
                offer(command, score: Score.frequentHistory, source: .history)
            }
            for command in agentCommands.suffix(1) {
                offer(command, score: Score.recentAgent, source: .agent)
            }
        } else if stale {
            // 行内容已不可信：只按「最常用」给，绝不按前缀匹配 —— 拿错前缀
            // 拼出来的命令比不给更糟。
            for command in frequentCommands(history, limit: limit) {
                offer(command, score: Score.frequentHistory, source: .history)
            }
        } else {
            // 整行前缀匹配：用户已经在敲这条命令了，它几乎一定是想跑的。
            for command in history where command.hasPrefix(line) {
                offer(command, score: Score.wholeLineHistory, source: .history)
            }
            for command in agentCommands where command.hasPrefix(line) {
                offer(command, score: Score.wholeLineAgent, source: .agent)
            }
            // token 级补全：把候选拼回「已输入的前半截 + 候选」。
            for command in history where firstWord(command).hasPrefix(token) {
                offer(command, score: Score.tokenHistory, source: .history)
            }
            for command in agentCommands where firstWord(command).hasPrefix(token) {
                offer(command, score: Score.tokenAgent, source: .agent)
            }
            for entry in entries where entry.lowercased().hasPrefix(token.lowercased()) {
                offer(leadingContext + entry, score: Score.tokenPath, source: .path)
            }
            // 历史里以同一个 token 开头的子命令（`git ` → `git status`）。
            for command in history where command.hasPrefix(token) && command != token {
                offer(command, score: Score.tokenHistory - 5, source: .history)
            }
        }

        return best.values
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.order < rhs.order
            }
            .prefix(limit)
            .map { $0.suggestion }
    }

    /// 出现次数降序、同次数时取更近的（历史是旧 → 新）。
    private static func frequentCommands(_ history: [String], limit: Int) -> [String] {
        var count: [String: Int] = [:]
        var lastSeen: [String: Int] = [:]
        for (index, raw) in history.enumerated() {
            let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, !command.hasPrefix("#") else { continue }
            count[command, default: 0] += 1
            lastSeen[command] = index
        }
        return count.keys
            .sorted { lhs, rhs in
                let l = count[lhs] ?? 0, r = count[rhs] ?? 0
                return l != r ? l > r : (lastSeen[lhs] ?? 0) > (lastSeen[rhs] ?? 0)
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func firstWord(_ command: String) -> String {
        guard let index = command.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return command }
        return String(command[command.startIndex ..< index])
    }
}

/// 行内灰字（ghost completion）的选择规则。纯函数，无 IO。
///
/// 灰字是宠物**唯一**可以主动递到用户手边的东西，门槛必须比气泡里的
/// 候选更严：行非空、影子可信、候选是整行的严格前缀 —— 三个条件缺一不可。
/// token 级拼接候选（`git s` → `swift build` 这种）只配进气泡，绝不能
/// 直接糊在光标后面，那不是「补全」是「抢话」。
enum PetGhostCompletion {

    /// - Returns: 需要追加到当前行末尾的部分（不含已输入内容）；没有合格候选时为 nil。
    static func suffix(line: String, isExact: Bool, suggestions: [PetSuggestion]) -> String? {
        guard isExact, !line.isEmpty else { return nil }
        // 候选已按分数排序，第一个严格前缀匹配的就是最该补的那条。
        for suggestion in suggestions where suggestion.command.hasPrefix(line) && suggestion.command != line {
            return String(suggestion.command.dropFirst(line.count))
        }
        return nil
    }
}
