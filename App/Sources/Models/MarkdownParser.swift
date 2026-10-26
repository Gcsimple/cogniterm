import Foundation

/// 行内的一段最小富文本。
enum MarkdownInline: Equatable {
    case text(String)
    case code(String)
    case bold(String)
    case link(text: String, href: String)
    /// 看起来是路径的片段（`App/Sources/x.swift`、`~/foo`、`./a.sh`）。
    /// 单独一类而不是并进 `.text`：视图层要把它画成固定样式的 chip。
    case path(String)
}

/// 对话区支持的块结构。
enum MarkdownBlock: Equatable {
    case paragraph([MarkdownInline])
    case codeBlock(language: String?, code: String)
    case bullets([[MarkdownInline]])
    case numbered(start: Int, items: [[MarkdownInline]])
}

/// 轻量 Markdown 解析器：**只认对话里真会出现的结构**。
///
/// 为什么自研而不是引 `swift-markdown`：
/// 1. 我们只要 5 种块 + 4 种行内标记，通用库带来的复杂度远超收益；
/// 2. 更重要的——**排版权要留在自己手里**。这个对话区是刻意克制的
///    （正文裸文本、只有代码块有装饰），引一个通用渲染器等于把「长什么样」
///    交给第三方默认值。
///
/// 纯函数、无 SwiftUI 依赖：单测直接打 `parse(_:)`，不需要起 shell 或窗口。
enum MarkdownParser {

    // MARK: - 块解析

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [(Int, String)] = []
        var fence: (language: String?, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(parseInline(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets.map(parseInline)))
            bullets.removeAll()
        }
        func flushNumbered() {
            guard !numbered.isEmpty else { return }
            blocks.append(.numbered(start: numbered[0].0,
                                    items: numbered.map { parseInline($0.1) }))
            numbered.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushNumbered()
        }

        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // ── fence 之内：一律原样累积。代码里的 `#`、`-`、`>` 都是代码。
            if var open = fence {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    blocks.append(.codeBlock(language: open.language,
                                             code: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(raw)
                    fence = open
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let info = String(trimmed.drop { $0 == "`" || $0 == "~" })
                    .trimmingCharacters(in: .whitespaces)
                // 语言标记只取第一个词（```bash title=x 这种写法取 bash）
                let language = info.split(separator: " ").first.map(String.init)
                fence = (language, [])
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }
            // 水平线在对话里不承载信息，直接丢掉（否则会渲染成一行 `---`）。
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                continue
            }
            if let heading = headingText(trimmed) {
                flushAll()
                blocks.append(.paragraph([.bold(heading)]))
                continue
            }
            if let item = bulletText(trimmed) {
                flushParagraph()
                flushNumbered()
                bullets.append(item)
                continue
            }
            if let (number, item) = numberedText(trimmed) {
                flushParagraph()
                flushBullets()
                numbered.append((number, item))
                continue
            }
            if let quoted = quoteText(trimmed) {
                // 引用不做特殊排版：去掉 `> ` 记号后当普通段落，避免出现一排竖线。
                flushBullets()
                flushNumbered()
                paragraph.append(quoted)
                continue
            }

            flushBullets()
            flushNumbered()
            paragraph.append(trimmed)
        }

        // 未闭合的 fence 也要把内容吐出来——否则模型少写三个反引号就吞掉整段代码。
        if let open = fence {
            blocks.append(.codeBlock(language: open.language,
                                     code: open.lines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    // MARK: - 行内解析

    /// 扫描顺序要紧：先 `code`（里面的 `*` 和 `[` 都是字面量），再 `**bold**`，
    /// 最后 `[text](href)`。都匹配不上才落到裸 token 识别。
    static func parseInline(_ text: String) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var buffer = ""
        var i = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(contentsOf: splitBareTokens(buffer))
            buffer = ""
        }

        while i < text.endIndex {
            let ch = text[i]

            if ch == "`" {
                let after = text.index(after: i)
                if let close = text[after...].firstIndex(of: "`") {
                    flush()
                    out.append(.code(String(text[after..<close])))
                    i = text.index(after: close)
                    continue
                }
            }

            if ch == "*", text[i...].hasPrefix("**") {
                let start = text.index(i, offsetBy: 2)
                if let close = text[start...].range(of: "**")?.lowerBound {
                    flush()
                    out.append(.bold(String(text[start..<close])))
                    i = text.index(close, offsetBy: 2)
                    continue
                }
            }

            if ch == "[" {
                let afterOpen = text.index(after: i)
                if let closeBracket = text[afterOpen...].firstIndex(of: "]") {
                    let afterBracket = text.index(after: closeBracket)
                    if afterBracket < text.endIndex, text[afterBracket] == "(" {
                        let hrefStart = text.index(after: afterBracket)
                        if let closeParen = text[hrefStart...].firstIndex(of: ")") {
                            flush()
                            out.append(.link(text: String(text[afterOpen..<closeBracket]),
                                             href: String(text[hrefStart..<closeParen])))
                            i = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }

            buffer.append(ch)
            i = text.index(after: i)
        }
        flush()
        return out.isEmpty ? [.text(text)] : out
    }

    // MARK: - 裸 token（URL / 路径）

    /// 把一段纯文本切成「空白 + 词」序列，词里挑出 URL 与路径。
    ///
    /// 两个边界都算分词符：
    /// 1. **空白**——保留原样，`ls    -la` 的对齐不能被吃掉；
    /// 2. **CJK 字符与全角标点**——中文没有词间空格，`TerminalPaneView.swift，见`
    ///    在只按空白切分时会变成一个巨长的「词」，于是路径和 URL 全都认不出来
    ///    （2026-10-26 被单测抓到）。
    ///
    /// 代价：中文文件名（`文档/说明.md`）会被拆开而不再识别成路径 chip。
    /// 这是有意的取舍——宁可少标一个 chip，也不能让整句中英混排失去识别。
    static func splitBareTokens(_ text: String) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var pending = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || isCJK(character) {
                pending.append(character)
                index = text.index(after: index)
                continue
            }

            var end = index
            while end < text.endIndex, !text[end].isWhitespace, !isCJK(text[end]) {
                end = text.index(after: end)
            }
            let rawWord = String(text[index..<end])
            let (core, tail) = splitTrailingPunctuation(rawWord)

            if looksLikeURL(core) {
                if !pending.isEmpty { out.append(.text(pending)); pending = "" }
                out.append(.link(text: core, href: core))
                pending = tail
            } else if looksLikePath(core) {
                if !pending.isEmpty { out.append(.text(pending)); pending = "" }
                out.append(.path(core))
                pending = tail
            } else {
                pending += rawWord
            }
            index = end
        }

        if !pending.isEmpty { out.append(.text(pending)) }
        return out
    }

    /// 汉字、假名、CJK 标点、全角形式。
    private static func isCJK(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x303F,   // CJK 标点（、。「」…）
                 0x3040...0x30FF,   // 平假名 / 片假名
                 0x3400...0x4DBF,   // 扩展 A
                 0x4E00...0x9FFF,   // 基本区
                 0xFF00...0xFFEF:   // 全角形式（，（）：；！？）
                return true
            default:
                continue
            }
        }
        return false
    }

    /// 句末标点不属于 URL/路径（`见 http://x.com/a。` 里的句号要留在正文）。
    /// 全角标点也要剥：中文回复里 URL 后面几乎总是直接跟「。」而不是空格。
    private static func splitTrailingPunctuation(_ token: String) -> (String, String) {
        var core = token
        var tail = ""
        while let last = core.last, ".,;:!?)]}'\"。，、；：！？）》」』”’".contains(last) {
            tail = String(last) + tail
            core.removeLast()
        }
        return (core, tail)
    }

    static func looksLikeURL(_ token: String) -> Bool {
        token.hasPrefix("http://") || token.hasPrefix("https://")
    }

    /// 路径识别刻意保守：误判会把普通括号短语画成彩色 chip，比不识别更吵。
    ///
    /// 只认两种：
    /// - 以 `/`、`~/`、`./`、`../` 开头，且带扩展名或至少两段；
    /// - 带已知扩展名（`Foo.swift`、`a/b.json`）。
    static func looksLikePath(_ token: String) -> Bool {
        guard token.count > 2, !token.contains("://"), !token.contains("`") else { return false }
        let knownExtensions: Set<String> = [
            "swift", "md", "json", "sh", "py", "js", "ts", "yml", "yaml", "toml",
            "txt", "plist", "lock", "pbxproj", "sql", "go", "rs", "java", "css", "html",
        ]
        let ext = (token as NSString).pathExtension.lowercased()
        let absoluteish = token.hasPrefix("/") || token.hasPrefix("~/")
            || token.hasPrefix("./") || token.hasPrefix("../")
        if absoluteish {
            if knownExtensions.contains(ext) { return true }
            return token.split(separator: "/").count > 1
        }
        guard token.contains("/") || knownExtensions.contains(ext) else { return false }
        return knownExtensions.contains(ext)
    }

    // MARK: - 行首记号

    private static func headingText(_ trimmed: String) -> String? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private static func bulletText(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedText(_ trimmed: String) -> (Int, String)? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    private static func quoteText(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("> ") else { return nil }
        return String(trimmed.dropFirst(2))
    }
}
