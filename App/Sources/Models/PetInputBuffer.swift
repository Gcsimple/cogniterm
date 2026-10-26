//
//  PetInputBuffer.swift
//  CogniTerm
//
//  「用户现在这一行打了什么」的影子缓冲区。
//
//  为什么不去读终端屏幕：SwiftTerm core 里 OSC 133 的语义标记已经实现
//  （`SemanticPrompt.swift` / `buffer.semanticInput`），但**没有任何 shell
//  侧集成去发这些标记**，App 侧也没有公开读取入口 —— 也就是说「提示符在
//  第几列结束」此刻是拿不到的。而 `TerminalViewDelegate.send(source:data:)`
//  是键盘、粘贴、鼠标编码进 PTY 的**唯一漏斗**（`TerminalPaneView.swift:969`），
//  所有输入都过它。于是我们在旁边自己记一份，就等价于「用户打了什么」，
//  完全不需要知道提示符长什么样 —— 每按下一次 ↵，缓冲区清空，新行从零开始。
//
//  代价必须说清楚：会改写行的按键（Tab 补全、↑ 历史、Ctrl-R、⌥←按词移动）
//  我们无法从字节流反推结果。这类按键一律把状态打成 `.stale`，宠物随之停止
//  行内补全、只给「下一步建议」，按一次 ↵ 自动复原。**宁可不给，不给错的。**
//

import Foundation

struct PetInputBuffer: Equatable {

    /// 影子与真实行是否一致。`stale` 携带的原因会直接显示给用户，
    /// 不做「偷偷降级」——用户得知道为什么宠物忽然不接话了。
    enum Confidence: Equatable {
        case exact
        case stale(String)

        var isExact: Bool { self == .exact }
    }

    /// 当前这一行的内容（不含提示符，也不含行尾换行）。
    private(set) var text: String = ""
    private(set) var confidence: Confidence = .exact

    /// 多字节 UTF-8 字符的拼装残片。中文输入法逐字上屏时，一个「字」
    /// 会跨多次 `send` 到达，不能在字节边界上切断。
    private var pendingUTF8: [UInt8] = []
    private var inBracketedPaste = false

    /// 超过这个长度基本可以断定不是「在敲命令」而是有别的程序在读输入，
    /// 继续跟随只会让内存与气泡一起失控。
    private static let maxLength = 4096

    private static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC[200~
    private static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]    // ESC[201~

    // MARK: 派生读法

    /// 正在补全的那个 token：最后一个空白之后的部分。
    var trailingToken: String {
        guard let index = text.lastIndex(where: { $0 == " " || $0 == "\t" }) else {
            return text
        }
        return String(text[text.index(after: index)...])
    }

    /// token 之前的部分（含末尾空白），用于把候选拼回整行。
    var leadingContext: String {
        let token = trailingToken
        guard token.count <= text.count else { return "" }
        return String(text.prefix(text.count - token.count))
    }

    var isEmpty: Bool { text.isEmpty }

    /// 是否正处在括号粘贴序列中。粘贴内容里**可能**恰好带裸 Tab 字节，
    /// 这种 Tab 绝不能被当成「接受行内补全」截走。
    var isPasting: Bool { inBracketedPaste }

    // MARK: 消费字节

    /// 喂入一段**即将写进 PTY** 的字节。调用点唯一：`TerminalSession.send`。
    mutating func consume(_ data: ArraySlice<UInt8>) {
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]

            if inBracketedPaste {
                if matches(data, at: index, Self.bracketedPasteEnd) {
                    inBracketedPaste = false
                    index += Self.bracketedPasteEnd.count
                    continue
                }
                pendingUTF8.append(byte)
                flushPendingUTF8()
                index += 1
                continue
            }

            switch byte {
            case 0x1B:
                // 转义序列：`ESC[200~` 开括号粘贴，其余一律视为「会改写行」。
                if matches(data, at: index, Self.bracketedPasteStart) {
                    inBracketedPaste = true
                    index += Self.bracketedPasteStart.count
                } else {
                    index = skipEscapeSequence(data, from: index)
                    markStale("方向键或历史召回改写了当前行")
                }
            case 0x09:
                markStale("shell 补全改写了当前行")
                index += 1
            case 0x0D, 0x0A:
                // ↵：行已提交，新行从零开始 —— 这是唯一能让 `.stale` 复原的事件。
                reset()
                index += 1
            case 0x7F, 0x08:
                deleteBackward()
                index += 1
            case 0x15:  // Ctrl-U：kill 整行
                text = ""
                pendingUTF8 = []
                index += 1
            case 0x17:  // Ctrl-W：kill 前一个词
                deleteWordBackward()
                index += 1
            case 0x03, 0x04:  // Ctrl-C / Ctrl-D
                reset()
                index += 1
            case 0x00 ... 0x1F:
                // 其余控制键（Ctrl-R 反向搜索、Ctrl-A/E 行首行尾……）都会
                // 移动或改写行内某处，我们无从得知结果。
                markStale("控制键改写了当前行")
                index += 1
            default:
                pendingUTF8.append(byte)
                flushPendingUTF8()
                index += 1
            }
        }
    }

    /// 外部主动清空（例如用户在别处点了「清屏」）。
    mutating func reset() {
        text = ""
        confidence = .exact
        pendingUTF8 = []
        inBracketedPaste = false
    }

    // MARK: 内部

    private mutating func append(_ piece: String) {
        guard !piece.isEmpty else { return }
        guard text.count + piece.count <= Self.maxLength else {
            markStale("当前行超出预期长度，已停止跟随")
            return
        }
        text += piece
    }

    private mutating func deleteBackward() {
        guard !text.isEmpty else { return }
        text.removeLast()  // 按「字素簇」删，中文与 emoji 都不会删半个
    }

    private mutating func deleteWordBackward() {
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        while let last = text.last, last != " " && last != "\t" { text.removeLast() }
    }

    private mutating func markStale(_ reason: String) {
        guard confidence.isExact else { return }  // 第一次的原因更接近现场
        confidence = .stale(reason)
    }

    /// 按 lead byte 判断该字符要几个字节，够了才上屏。
    private mutating func flushPendingUTF8() {
        guard let first = pendingUTF8.first else { return }
        let needed: Int
        switch first {
        case 0x00 ... 0x7F: needed = 1
        case 0xC0 ... 0xDF: needed = 2
        case 0xE0 ... 0xEF: needed = 3
        case 0xF0 ... 0xF7: needed = 4
        default:
            pendingUTF8 = []
            markStale("输入编码无法识别")
            return
        }
        guard pendingUTF8.count >= needed else { return }
        let slice = pendingUTF8.prefix(needed)
        pendingUTF8.removeFirst(needed)
        if let piece = String(bytes: slice, encoding: .utf8) {
            append(piece)
        }
    }

    private func matches(_ data: ArraySlice<UInt8>, at index: ArraySlice<UInt8>.Index, _ pattern: [UInt8]) -> Bool {
        guard index + pattern.count <= data.endIndex else { return false }
        for offset in 0 ..< pattern.count where data[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// 跳过一条转义序列，返回序列之后的第一个字节下标。
    /// CSI（`ESC [ … 终止字节`）要整条吃掉，否则序列里的数字会被当成用户输入。
    private func skipEscapeSequence(_ data: ArraySlice<UInt8>, from index: ArraySlice<UInt8>.Index) -> ArraySlice<UInt8>.Index {
        var cursor = index + 1
        guard cursor < data.endIndex else { return cursor }
        let kind = data[cursor]
        guard kind == 0x5B || kind == 0x4F else { return cursor + 1 }  // CSI / SS3
        cursor += 1
        while cursor < data.endIndex, !(0x40 ... 0x7E).contains(data[cursor]) {
            cursor += 1
        }
        return cursor < data.endIndex ? cursor + 1 : cursor
    }
}

/// 「接受行内灰字补全」的按键判定。**纯字节匹配**，不依赖 AppKit：
/// 键盘事件在到达 `TerminalSession.send` 之前就按这张表决定是否截获。
///
/// 只认两个裸键，多一个修饰键都不匹配（Shift-Tab、Alt/Option-→、
/// kitty 键盘协议编码出的加长序列一律原样透传给 shell）。
enum PetGhostKey {

    /// Tab：`\t`。注意 shell 自己的 Tab 补全也用这个键——只有行内灰字
    /// 正在显示时才截获，没有灰字时 Tab 与从前完全等价。
    static let tab: [UInt8] = [0x09]

    /// 裸 →：`ESC [ C`。fish shell 同款手感：灰字在的时候 → 整条接受。
    static let acceptForward: [UInt8] = [0x1B, 0x5B, 0x43]

    static func isAcceptKey(_ data: ArraySlice<UInt8>) -> Bool {
        data == tab[...] || data == acceptForward[...]
    }
}
