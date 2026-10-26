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
        /// 内置的 macOS / Linux 常用命令目录（`PetBuiltInCommands`）。
        case builtIn

        var label: String {
            switch self {
            case .history: return "历史"
            case .path: return "路径"
            case .agent: return "对话"
            case .builtIn: return "内置"
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
    /// 内置命令的整行前缀命中：排在个人历史/对话之后，但压过一切 token 级
    /// 猜测 —— 用户已经把前缀敲对了，一条「准确但通用」的命令也比
    /// 「个人化但只是首词沾边」的命令更像他要的。
    static let wholeLineBuiltIn = 85
    static let tokenHistory = 80
    static let tokenAgent = 70
    static let tokenPath = 60
    /// 仅在「命令起始位」生效的内置首词补全。
    static let tokenBuiltIn = 55
    /// 空行时「最常用」压过「刚聊到的」：输入法的手感来自频次，
    /// 频率最高的那条一旦排到第二，宠物就会显得比人还善变。
    static let frequentHistory = 40
    static let recentAgent = 20
    /// 空行 / stale 时，个人数据排不满前五的**剩余位置**才由内置起手式兜底。
    /// 必须低于 recentAgent：和 agent 聊出一条命令后空行，第一条仍该是那条。
    static let starterBuiltIn = 15
}

enum PetSuggestionEngine {

    /// - Parameters:
    ///   - entries: `cwd` 下的条目名，目录已带尾部 `/`（由调用方补齐，
    ///     这样引擎不必再问文件系统一次）。
    ///   - history: 旧 → 新排列的命令历史。
    ///   - builtIns: 内置命令目录，默认取 `PetBuiltInCommands.catalog`；
    ///     测试可注入小目录，不必依赖内置数据的具体内容。
    static func suggest(
        line: String,
        leadingContext: String,
        token: String,
        kind: PetInputBuffer.Confidence,
        entries: [String],
        history: [String],
        agentCommands: [String],
        builtIns: [PetBuiltInCommand] = PetBuiltInCommands.catalog,
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
            // 个人数据排不满时（新装、空历史），内置起手式补剩余位置。
            for entry in builtIns where entry.isStarter {
                offer(entry.command, score: Score.starterBuiltIn, source: .builtIn)
            }
        } else if stale {
            // 行内容已不可信：只按「最常用」给，绝不按前缀匹配 —— 拿错前缀
            // 拼出来的命令比不给更糟。
            for command in frequentCommands(history, limit: limit) {
                offer(command, score: Score.frequentHistory, source: .history)
            }
            // 同样只允许起手式兜底，不允许内置前缀匹配（前缀此刻不可信）。
            for entry in builtIns where entry.isStarter {
                offer(entry.command, score: Score.starterBuiltIn, source: .builtIn)
            }
        } else {
            // 整行前缀匹配：用户已经在敲这条命令了，它几乎一定是想跑的。
            for command in history where command.hasPrefix(line) {
                offer(command, score: Score.wholeLineHistory, source: .history)
            }
            for command in agentCommands where command.hasPrefix(line) {
                offer(command, score: Score.wholeLineAgent, source: .agent)
            }
            // 内置整行前缀：冷启动没有历史时，宠物也能把 `git st` 补成
            // `git status`；分数低于个人数据，同一条命令历史里有时让位给「历史」。
            for entry in builtIns where entry.command.hasPrefix(line) {
                offer(entry.command, score: Score.wholeLineBuiltIn, source: .builtIn)
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
            // 内置首词补全**只在命令起始位**生效：打 `git s` 时绝不能把
            // 首词以 s 开头的 `ssh ...`、`sudo ...` 当成 `git` 的参数补进来。
            if leadingContext.isEmpty {
                for entry in builtIns where firstWord(entry.command).hasPrefix(token) {
                    offer(entry.command, score: Score.tokenBuiltIn, source: .builtIn)
                }
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

/// 自动展开面板的可见性策略。纯函数 —— 「什么时候该主动把候选列表弹出来」
/// 是产品手感，必须能单测、不能散落在视图动画里。
///
/// 设计取舍：行内灰字递的是 top1；面板存在的意义是 top1 之外**还有分叉**
/// （`git s` → status / stash / switch）。所以只有 1 条候选时不展开，
/// 灰字足够了，弹了只是噪音。
enum PetAutoPanelPolicy {

    static func isVisible(
        input: PetInputBuffer,
        suggestions: [PetSuggestion],
        popoverPresented: Bool,
        dismissed: Bool
    ) -> Bool {
        // 完整 popover 开着时不重复弹；用户明确关过（Esc / ×）这一行不再弹；
        // 粘贴中、影子不可信、空行 —— 都不弹。
        guard !popoverPresented,
              !dismissed,
              !input.isPasting,
              input.confidence.isExact,
              !input.text.isEmpty
        else { return false }
        return suggestions.count >= 2
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

/// 一条内置命令及其适用平台。
struct PetBuiltInCommand: Equatable {
    enum Platform: String, Equatable {
        case all
        case macOS
        case linux
    }

    let command: String
    let platforms: Set<Platform>
    /// 空行 / 冷启动时的「起手式」。只有双平台通用、零风险的命令才配打这个标。
    let isStarter: Bool
}

/// 内置的 macOS / Linux 常用命令目录。
///
/// 收录纪律（改目录前先读）：
/// 1. 只收「键入即可运行，或顶多替换一个词」的形态；不收 `<file>` 这类
///    占位符半成品 —— 用户得先删占位符，比不提示更烦。
/// 2. 永不收破坏性示例（`rm -rf /`、`chmod 777`、`mkfs` 之流），
///    删除/提权类只给安全形态（`rm -i`、`sudo apt update`）。
/// 3. 平台专属命令打标签。App 只跑在 macOS，但终端里随时可能 SSH 进
///    Linux 机器，所以两套都保留 —— 平台专属命令只在用户**敲出对应前缀**
///    时才出现，空行里永远只有跨平台起手式，不会刷屏。
/// 4. 数组顺序就是同分时的先后：同一前缀命中多条时（`git s` → status /
///    stash / switch），越常用的排越前。
enum PetBuiltInCommands {

    /// 空行起手式：跨平台、零风险、五条以内（气泡前五条要给个人数据留位）。
    static let starters = ["ls -la", "pwd", "cd ..", "clear", "git status"]

    /// 双平台通用。顺序按粗略使用频率排，决定前缀命中时谁排第一。
    private static let crossPlatform = [
        "ls -la",
        "ls -lah",
        "pwd",
        "cd ..",
        "cd ~",
        "clear",
        "git status",
        "cat file.txt",
        "less file.txt",
        "head -n 20 file.txt",
        "tail -f app.log",
        "touch file.txt",
        "mkdir -p path/to/dir",
        "cp -R source destination",
        "mv old new",
        "rm -i file.txt",
        "chmod +x ./script.sh",
        "chmod 644 file.txt",
        "ln -s target link",
        "du -sh *",
        "df -h",
        "find . -name \"*.swift\"",
        "grep -rn \"TODO\" .",
        "wc -l file.txt",
        "diff -u old new",
        "tree -L 2",
        "which git",
        "file ./*",
        "history | tail -n 20",
        "whoami",
        "id",
        "uname -a",
        "uptime",
        "date",
        "env",
        "printenv PATH",
        "man ls",
        "ps aux",
        "ps aux | grep ssh",
        "pgrep -fl ssh",
        "lsof -i :8080",
        "top",
        "htop",
        "ping -c 4 example.com",
        "curl -I https://example.com",
        "curl -L -O https://example.com/file",
        "ssh user@host",
        "scp file user@host:~/",
        "tar -czf archive.tar.gz folder/",
        "tar -xzf archive.tar.gz",
        "zip -r archive.zip folder/",
        "unzip archive.zip",
        "dig +short example.com",
        "nc -zv example.com 443",
        "git diff",
        "git diff --staged",
        "git log --oneline -20",
        "git branch -a",
        "git switch -c feature",
        "git switch -",
        "git add -p",
        "git commit -m \"message\"",
        "git stash push -m \"wip\"",
        "git stash list",
        "git pull --rebase",
        "git push -u origin HEAD",
        "git fetch --all --prune",
        "git restore file.txt",
        "git remote -v",
        "python3 -m http.server 8000",
        "npm install",
        "npm run dev",
        "npx serve .",
        "docker ps",
        "docker compose up -d",
        "docker logs -f container",
        "make"
    ]

    private static let macOSOnly = [
        "open .",
        "open -a Safari https://example.com",
        "pbcopy < file.txt",
        "pbpaste",
        "brew install git",
        "brew update",
        "brew upgrade",
        "brew search wget",
        "mdfind \"query\"",
        "softwareupdate --list",
        "defaults read",
        "shasum -a 256 file.txt",
        "say \"done\"",
        "diskutil list",
        // macOS 自带的是 BSD sed，-i 必须多带一个空串参数，照抄 Linux
        // 写法会报错 —— 这种平台差异正是内置提示该替用户记住的东西。
        "sed -i '' 's/old/new/g' file.txt"
    ]

    private static let linuxOnly = [
        "sudo apt update",
        "sudo apt install -y git",
        "systemctl status nginx",
        "sudo systemctl restart nginx",
        "journalctl -u nginx -f",
        "free -h",
        "lsblk",
        "cat /etc/os-release",
        "ip addr",
        "ss -tlnp",
        "xdg-open .",
        "xclip -selection clipboard < file.txt",
        "sha256sum file.txt",
        "chown user:group file.txt",
        "sed -i 's/old/new/g' file.txt",
        "wget https://example.com/file",
        "sudo !!"
    ]

    static let catalog: [PetBuiltInCommand] =
        crossPlatform.map { PetBuiltInCommand(command: $0, platforms: [.all],
                                              isStarter: starters.contains($0)) }
        + macOSOnly.map { PetBuiltInCommand(command: $0, platforms: [.macOS], isStarter: false) }
        + linuxOnly.map { PetBuiltInCommand(command: $0, platforms: [.linux], isStarter: false) }
}
