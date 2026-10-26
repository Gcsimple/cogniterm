//
//  PetContextStore.swift
//  CogniTerm
//
//  宠物能看到的「外部世界」：用户自己的命令历史、刚在对话里出现过的命令、
//  当前目录下有什么。三者都是只读的旁路信息，任何一个取不到都只是少几条
//  候选，不影响终端本身 —— 所以全部 fail-soft。
//

import Foundation

@MainActor
final class PetContextStore: ObservableObject {

    static let shared = PetContextStore()

    /// 对话里最近出现过的命令（`MarkdownCodeBlockView` 渲染时记一笔）。
    /// 只留最近的若干条：宠物给的是「刚才聊到的那条」，不是命令大全。
    @Published private(set) var agentCommands: [String] = []

    private var cachedHistory: [String]?

    private static let agentCommandLimit = 12
    private static let historyLimit = 2000

    private init() {}

    // MARK: 对话侧

    /// 记一条 agent 给出的命令。多行块**整段不要** —— 那是在给脚本，
    /// 不是给一条能直接跑的指令，塞进候选项只会诱导用户盲跑。
    func recordAgentCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return }
        guard !agentCommands.contains(trimmed) else { return }
        agentCommands.append(trimmed)
        if agentCommands.count > Self.agentCommandLimit {
            agentCommands.removeFirst(agentCommands.count - Self.agentCommandLimit)
        }
    }

    // MARK: 历史

    /// 首次读取后常驻内存：`~/.zsh_history` 可能有几万行，每次敲键都读盘
    /// 不值得。会话内新跑的命令由「整行前缀匹配」自己补上。
    func history() -> [String] {
        if let cachedHistory { return cachedHistory }
        let loaded = Self.loadHistory(limit: Self.historyLimit)
        cachedHistory = loaded
        return loaded
    }

    /// 让下一次 `history()` 重新读盘（用户点了「重载历史」才需要）。
    func invalidateHistory() {
        cachedHistory = nil
    }

    nonisolated static func historyFileURLs(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        // zsh 优先，其次 bash —— 本 App 的默认 shell 是 `/bin/zsh`
        // （`PseudoTerminal` 的 `executablePath` 默认值），bash 只是兜底。
        return [home.appendingPathComponent(".zsh_history"),
                home.appendingPathComponent(".bash_history")]
    }

    nonisolated static func loadHistory(limit: Int) -> [String] {
        for url in historyFileURLs() {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            // 历史文件里可能有非法字节（粘贴进来的二进制），整体按 UTF-8 宽松解。
            let raw = String(decoding: data, as: UTF8.self)
            let parsed = parseHistory(raw)
            if !parsed.isEmpty {
                return Array(parsed.suffix(limit))
            }
        }
        return []
    }

    /// zsh 的扩展历史每行形如 `: 1698345678:0;git status`。
    /// 非扩展格式（`sh` 风格或 `setopt no_extended_history`）就是一行一条命令。
    ///
    /// 判定依据取**第一行**：混排文件不存在，而逐行判断会把多行命令的
    /// 续行（不带 `: ` 前缀）误当成一条独立命令。
    nonisolated static func parseHistory(_ raw: String) -> [String] {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return [] }
        let extended = first.hasPrefix(": ")

        var commands: [String] = []
        for line in lines {
            let command: String
            if extended {
                guard let separator = line.firstIndex(of: ";"), line.hasPrefix(": ") else { continue }
                command = String(line[line.index(after: separator)...])
            } else {
                command = line
            }
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // 多行命令的续行以反斜杠结尾，拼不起来就别给候选。
            guard !trimmed.hasSuffix("\\") else { continue }
            commands.append(trimmed)
        }
        return commands
    }

    // MARK: 目录

    /// 列一个目录下的条目名，子目录带尾部 `/`。
    /// 只读一层：宠物是「顺手补一下」，不是文件浏览器。
    nonisolated static func listEntries(at path: String?, limit: Int = 600) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        return items
            .prefix(limit)
            .map { item in
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return isDirectory ? item.lastPathComponent + "/" : item.lastPathComponent
            }
            .sorted()
    }
}
