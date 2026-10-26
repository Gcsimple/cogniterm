//
//  PetSuggestionTests.swift
//  CogniTermTests
//
//  宠物这一层的两个纯逻辑部分：影子输入缓冲区与候选打分。
//  这两块一旦错，宠物就会「看着人打字却说错话」，比没有宠物更烦。
//

import XCTest
@testable import CogniTerm

final class PetInputBufferTests: XCTestCase {

    private func feed(_ buffer: inout PetInputBuffer, _ text: String) {
        buffer.consume(ArraySlice(Array(text.utf8)))
    }

    func testTypingBuildsTheCurrentLine() {
        var buffer = PetInputBuffer()
        feed(&buffer, "git sta")
        XCTAssertEqual(buffer.text, "git sta")
        XCTAssertEqual(buffer.trailingToken, "sta")
        XCTAssertEqual(buffer.leadingContext, "git ")
        XCTAssertTrue(buffer.confidence.isExact)
    }

    func testEnterClearsTheLine() {
        var buffer = PetInputBuffer()
        feed(&buffer, "ls -la")
        buffer.consume(ArraySlice([0x0D]))
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.confidence, .exact)
    }

    func testTabMarksStaleAndEnterRecovers() {
        var buffer = PetInputBuffer()
        feed(&buffer, "cd Cogn")
        buffer.consume(ArraySlice([0x09]))
        guard case .stale = buffer.confidence else {
            return XCTFail("Tab 补全会改写行，必须打成 stale")
        }
        XCTAssertEqual(buffer.text, "cd Cogn", "已输入的前半截仍要留着，只是不再做行内补全")

        buffer.consume(ArraySlice([0x0D]))
        XCTAssertEqual(buffer.confidence, .exact)
        XCTAssertEqual(buffer.text, "")
    }

    func testArrowKeyEscapeIsSwallowedNotTyped() {
        var buffer = PetInputBuffer()
        feed(&buffer, "echo hi")
        // ↑：ESC [ A。若把序列里的字节当输入，行里会出现 "[A"。
        buffer.consume(ArraySlice([0x1B, 0x5B, 0x41]))
        XCTAssertEqual(buffer.text, "echo hi")
        guard case .stale = buffer.confidence else {
            return XCTFail("方向键会召回历史行，必须打成 stale")
        }
    }

    func testControlUClearsLineButKeepsConfidence() {
        var buffer = PetInputBuffer()
        feed(&buffer, "rm -rf build")
        buffer.consume(ArraySlice([0x15]))
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.confidence, .exact)
    }

    func testControlWDeletesOneWord() {
        var buffer = PetInputBuffer()
        feed(&buffer, "git commit -m")
        buffer.consume(ArraySlice([0x17]))
        XCTAssertEqual(buffer.text, "git commit ")
        buffer.consume(ArraySlice([0x17]))
        XCTAssertEqual(buffer.text, "git ")
    }

    func testBackspaceDeletesWholeGrapheme() {
        var buffer = PetInputBuffer()
        feed(&buffer, "echo 中文")
        buffer.consume(ArraySlice([0x7F]))
        XCTAssertEqual(buffer.text, "echo 中", "按字素簇删，不能把中文删成半个字节")
    }

    func testMultibyteCharacterSplitAcrossChunks() {
        var buffer = PetInputBuffer()
        let bytes = Array("终".utf8)  // 3 字节
        buffer.consume(ArraySlice(bytes[0 ... 0]))
        XCTAssertEqual(buffer.text, "", "字符没收全之前不能上屏")
        buffer.consume(ArraySlice(bytes[1 ... 2]))
        XCTAssertEqual(buffer.text, "终")
    }

    func testBracketedPasteIsLiteralAndCanContainNewlines() {
        var buffer = PetInputBuffer()
        buffer.consume(ArraySlice(Array("\u{1B}[200~".utf8)))
        feed(&buffer, "echo injected")
        buffer.consume(ArraySlice([0x0A]))
        feed(&buffer, "second")
        buffer.consume(ArraySlice(Array("\u{1B}[201~".utf8)))
        XCTAssertEqual(buffer.text, "echo injected\nsecond",
                       "括号粘贴是字面量，里面的换行不该被当成提交")
        XCTAssertEqual(buffer.confidence, .exact)
    }

    func testResetRestoresExact() {
        var buffer = PetInputBuffer()
        feed(&buffer, "vim")
        buffer.consume(ArraySlice([0x09]))
        buffer.reset()
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.confidence, .exact)
    }
}

final class PetSuggestionEngineTests: XCTestCase {

    private let history = [
        "git status",
        "git status",
        "git status",
        "git commit -m \"x\"",
        "npm run build",
        "ls -la",
        "cat Package.swift"
    ]

    func testWholeLinePrefixBeatsEverything() {
        let suggestions = PetSuggestionEngine.suggest(
            line: "git st",
            leadingContext: "",
            token: "git",
            kind: .exact,
            entries: [],
            history: history,
            agentCommands: ["git stash pop"]
        )
        XCTAssertEqual(suggestions.first?.command, "git status")
        XCTAssertEqual(suggestions.first?.source, .history)
        XCTAssertTrue(suggestions.contains { $0.command == "git stash pop" })
    }

    func testExactTypedLineIsNotOfferedBack() {
        let suggestions = PetSuggestionEngine.suggest(
            line: "ls -la",
            leadingContext: "",
            token: "ls",
            kind: .exact,
            entries: [],
            history: history,
            agentCommands: []
        )
        XCTAssertFalse(suggestions.contains { $0.command == "ls -la" },
                       "已经打完了就别再提示它")
    }

    func testEmptyLineOffersMostFrequent() {
        let suggestions = PetSuggestionEngine.suggest(
            line: "",
            leadingContext: "",
            token: "",
            kind: .exact,
            entries: [],
            history: history,
            agentCommands: ["git diff"]
        )
        XCTAssertEqual(suggestions.first?.command, "git status", "出现三次的最该排第一")
        XCTAssertTrue(suggestions.contains { $0.source == .agent })
    }

    func testStaleOnlyOffersFrequentNeverPrefixMatched() {
        let suggestions = PetSuggestionEngine.suggest(
            line: "git sta",
            leadingContext: "",
            token: "sta",
            kind: .stale("shell 补全改写了当前行"),
            entries: [],
            history: history,
            agentCommands: []
        )
        // stale 时行内容不可信，任何「已输入前缀 + 候选」的拼接都会拼错。
        XCTAssertTrue(suggestions.allSatisfy { !$0.command.hasPrefix("git sta ") })
        XCTAssertEqual(Set(suggestions.map(\.source)), [.history])
    }

    func testPathEntriesAreJoinedOntoLeadingContext() {
        let suggestions = PetSuggestionEngine.suggest(
            line: "cd Cog",
            leadingContext: "cd ",
            token: "Cog",
            kind: .exact,
            entries: ["CogniTerm/", "docs/", "Package.swift"],
            history: [],
            agentCommands: []
        )
        XCTAssertEqual(suggestions.first?.command, "cd CogniTerm/")
        XCTAssertEqual(suggestions.first?.source, .path)
    }

    func testDirectorySuffixSurvivesSoTheNextTokenStartsClean() {
        let suggestions = PetSuggestionEngine.suggest(
            line: "ls Doc",
            leadingContext: "ls ",
            token: "Doc",
            kind: .exact,
            entries: ["docs/"],
            history: [],
            agentCommands: []
        )
        XCTAssertEqual(suggestions.first?.command, "ls docs/")
    }

    func testLimitIsRespectedAndCandidatesAreDeduped() {
        let many = (0 ..< 40).map { "cmd\($0)" }
        let suggestions = PetSuggestionEngine.suggest(
            line: "cmd",
            leadingContext: "",
            token: "cmd",
            kind: .exact,
            entries: [],
            history: many,
            agentCommands: many,
            limit: 4
        )
        XCTAssertEqual(suggestions.count, 4)
        XCTAssertEqual(Set(suggestions.map(\.command)).count, 4)
    }
}

final class PetGhostCompletionTests: XCTestCase {

    private func suggestion(_ command: String, source: PetSuggestion.Source = .history) -> PetSuggestion {
        PetSuggestion(id: command, command: command, source: source, isRisky: false)
    }

    func testReturnsSuffixOfTopStrictPrefixCandidate() {
        let suggestions = [suggestion("git status"), suggestion("git stash")]
        XCTAssertEqual(
            PetGhostCompletion.suffix(line: "git st", isExact: true, suggestions: suggestions),
            "atus"
        )
    }

    func testSkipsTokenLevelCandidatesThatAreNotLinePrefixes() {
        // token 级拼接候选可能不以整行为前缀（打 "git s" 时按 token "s"
        // 命中的 "swift build"），这种不能糊在光标后面，要继续找下一条。
        let suggestions = [suggestion("swift build"), suggestion("git status")]
        XCTAssertEqual(
            PetGhostCompletion.suffix(line: "git s", isExact: true, suggestions: suggestions),
            "tatus"
        )
    }

    func testEmptyLineStaleStateAndFullyTypedLineAllReturnNil() {
        XCTAssertNil(PetGhostCompletion.suffix(line: "", isExact: true,
                                              suggestions: [suggestion("ls -la")]),
                     "空行不主动糊灰字（频率候选只配进气泡）")
        XCTAssertNil(PetGhostCompletion.suffix(line: "git", isExact: false,
                                              suggestions: [suggestion("git status")]),
                     "影子不可信（stale）时宁可不补")
        XCTAssertNil(PetGhostCompletion.suffix(line: "git status", isExact: true,
                                              suggestions: [suggestion("git status")]),
                     "已经打完的行不能再补一遍")
    }
}

final class PetGhostKeyTests: XCTestCase {

    func testBareTabAndBareRightArrowAreAcceptKeys() {
        XCTAssertTrue(PetGhostKey.isAcceptKey(ArraySlice([0x09])))
        XCTAssertTrue(PetGhostKey.isAcceptKey(ArraySlice([0x1B, 0x5B, 0x43])))
    }

    func testModifiedAndUnrelatedSequencesDoNotMatch() {
        XCTAssertFalse(PetGhostKey.isAcceptKey(ArraySlice([0x1B, 0x5B, 0x5A])), "Shift-Tab（BackTab）不截获")
        XCTAssertFalse(PetGhostKey.isAcceptKey(ArraySlice([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x43])),
                       "Alt-→ 的加长序列不截获，原样透传给 shell")
        XCTAssertFalse(PetGhostKey.isAcceptKey(ArraySlice([0x1B, 0x5B, 0x41])), "↑ 不是接受键")
        XCTAssertFalse(PetGhostKey.isAcceptKey(ArraySlice([0x61])), "普通字符不截获")
        XCTAssertFalse(PetGhostKey.isAcceptKey(ArraySlice<UInt8>([])))
    }

    func testIsPastingSpansTheWholeBracketedSequence() {
        var buffer = PetInputBuffer()
        XCTAssertFalse(buffer.isPasting)
        buffer.consume(ArraySlice(Array("\u{1B}[200~".utf8)))
        XCTAssertTrue(buffer.isPasting)
        // 粘贴内容里的裸 Tab 必须仍被视为粘贴，不能被灰字接受逻辑抢走。
        buffer.consume(ArraySlice([0x09]))
        XCTAssertTrue(buffer.isPasting)
        buffer.consume(ArraySlice(Array("\u{1B}[201~".utf8)))
        XCTAssertFalse(buffer.isPasting)
    }
}

final class PetBuiltInCommandTests: XCTestCase {

    /// 不依赖目录具体内容的小目录，专门测引擎规则。
    private let smallCatalog: [PetBuiltInCommand] = [
        .init(command: "ls -la", platforms: [.all], isStarter: true),
        .init(command: "git status", platforms: [.all], isStarter: true),
        .init(command: "git stash", platforms: [.all], isStarter: false),
        .init(command: "ssh user@host", platforms: [.all], isStarter: false),
        .init(command: "sudo apt update", platforms: [.linux], isStarter: false)
    ]

    private func suggest(
        line: String,
        leadingContext: String = "",
        token: String,
        kind: PetInputBuffer.Confidence = .exact,
        entries: [String] = [],
        history: [String] = [],
        agentCommands: [String] = [],
        builtIns: [PetBuiltInCommand],
        limit: Int = 5
    ) -> [PetSuggestion] {
        PetSuggestionEngine.suggest(
            line: line, leadingContext: leadingContext, token: token, kind: kind,
            entries: entries, history: history, agentCommands: agentCommands,
            builtIns: builtIns, limit: limit
        )
    }

    func testFreshInstallCompletesFromBuiltInsAndFeedsGhostText() {
        let suggestions = suggest(line: "git st", token: "git", builtIns: smallCatalog)
        XCTAssertEqual(suggestions.first?.command, "git status")
        XCTAssertEqual(suggestions.first?.source, .builtIn, "空历史时内置命令要顶上")
        XCTAssertEqual(
            PetGhostCompletion.suffix(line: "git st", isExact: true, suggestions: suggestions),
            "atus",
            "内置候选同样要能驱动行内灰字"
        )
    }

    func testPersonalHistoryOutranksBuiltInForSameCommand() {
        let suggestions = suggest(
            line: "git st", token: "git",
            history: ["git status"],
            builtIns: smallCatalog
        )
        XCTAssertEqual(suggestions.first?.command, "git status")
        XCTAssertEqual(suggestions.first?.source, .history,
                       "同一条命令在个人历史里出现过时，来源必须标成历史而不是内置")
    }

    func testStarterBuiltInsFillEmptyLineOnlyWhenPersonalDataIsSparse() {
        let fresh = suggest(line: "", token: "", builtIns: smallCatalog)
        XCTAssertEqual(fresh.map(\.command), ["ls -la", "git status"])
        XCTAssertTrue(fresh.allSatisfy { $0.source == .builtIn })

        let rich = suggest(
            line: "", token: "",
            history: ["h1", "h2", "h3", "h4"],
            agentCommands: ["agent-cmd"],
            builtIns: smallCatalog
        )
        XCTAssertFalse(rich.contains { $0.source == .builtIn },
                       "前五条被个人数据占满时，内置起手式不该挤进来")
    }

    func testStaleStateNeverPrefixMatchesBuiltIns() {
        let suggestions = suggest(
            line: "git st", token: "sta",
            kind: .stale("shell 补全改写了当前行"),
            builtIns: smallCatalog
        )
        // `git stash` 不是 starter 但恰好以 "git st" 开头：它出现就说明
        // stale 状态下仍在按不可信前缀拼内置命令。
        XCTAssertFalse(suggestions.contains { $0.command == "git stash" },
                       "stale 的前缀不可信，非起手式的内置命令不许按前缀拼")
        // 允许出现的内置命令只能是与当前行无关的起手式（小目录里 git status
        // 恰好也是 starter，它作为通用兜底出现，与前缀匹配无关）。
        let starterCommands = Set(smallCatalog.filter(\.isStarter).map(\.command))
        XCTAssertTrue(suggestions
            .filter { $0.source == .builtIn }
            .allSatisfy { starterCommands.contains($0.command) })
        XCTAssertEqual(suggestions.first?.command, "ls -la", "只剩起手式兜底是允许的")
    }

    func testBuiltInFirstWordMatchesOnlyAtCommandPosition() {
        // 参数位（leadingContext 非空）：内置来源只允许整行前缀命中，
        // 不许把首词沾边的 ssh / sudo 当成 `git` 的参数塞进来。
        let atArgument = suggest(
            line: "git s", leadingContext: "git ", token: "s",
            builtIns: smallCatalog
        )
        for suggestion in atArgument where suggestion.source == .builtIn {
            XCTAssertTrue(suggestion.command.hasPrefix("git s"),
                          "参数位出现了非前缀的内置候选：\(suggestion.command)")
        }
        XCTAssertFalse(atArgument.contains { $0.command == "ssh user@host" })
        XCTAssertFalse(atArgument.contains { $0.command == "sudo apt update" })

        // 命令起始位：首词补全正常生效。
        let atCommandStart = suggest(line: "ss", token: "ss", builtIns: smallCatalog)
        XCTAssertTrue(atCommandStart.contains { $0.command == "ssh user@host" })
    }

    func testCatalogHygiene() {
        let catalog = PetBuiltInCommands.catalog

        // 无重复、无空行、单行；不收占位符半成品。
        let commands = catalog.map(\.command)
        XCTAssertEqual(Set(commands).count, commands.count, "内置目录有重复命令")
        for command in commands {
            XCTAssertFalse(command.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(command.contains("\n"))
            // 只拦 `<name>` 这种紧贴的占位符；`< file.txt` 的重定向是合法的。
            XCTAssertNil(command.range(of: "<[A-Za-z][A-Za-z0-9_]*>", options: .regularExpression),
                         "不应出现 <占位符>：\(command)")
            XCTAssertFalse(command.contains("> /dev/"), "不应出现写设备的示例：\(command)")
            XCTAssertFalse(command.contains("rm -rf /"), "永不收录破坏性示例：\(command)")
            XCTAssertFalse(command.contains("777"), "永不收录 777 放权示例：\(command)")
            XCTAssertFalse(command.contains("mkfs"), "永不收录格式化示例：\(command)")
        }

        // 起手式：≤5、全部来自跨平台组、且都在目录里。
        let starterEntries = catalog.filter(\.isStarter)
        XCTAssertLessThanOrEqual(starterEntries.count, 5)
        XCTAssertTrue(starterEntries.allSatisfy { $0.platforms == [.all] })
        XCTAssertEqual(Set(starterEntries.map(\.command)), Set(PetBuiltInCommands.starters))

        // 两个平台的专属命令都得有代表。
        XCTAssertTrue(catalog.contains { $0.platforms == [.macOS] })
        XCTAssertTrue(catalog.contains { $0.platforms == [.linux] })
    }
}

final class PetAutoPanelPolicyTests: XCTestCase {

    private let two = [
        PetSuggestion(id: "git status", command: "git status", source: .builtIn, isRisky: false),
        PetSuggestion(id: "git stash", command: "git stash", source: .builtIn, isRisky: false)
    ]

    private func typing(_ line: String) -> PetInputBuffer {
        var buffer = PetInputBuffer()
        buffer.consume(ArraySlice(Array(line.utf8)))
        return buffer
    }

    func testExpandsOnlyWhenExactNonEmptyLineHasAtLeastTwoCandidates() {
        XCTAssertTrue(PetAutoPanelPolicy.isVisible(
            input: typing("git s"), suggestions: two,
            popoverPresented: false, dismissed: false))

        let one = Array(two.prefix(1))
        XCTAssertFalse(PetAutoPanelPolicy.isVisible(
            input: typing("git s"), suggestions: one,
            popoverPresented: false, dismissed: false),
            "只有 1 条候选时灰字已经够了，不弹列表")
        XCTAssertFalse(PetAutoPanelPolicy.isVisible(
            input: PetInputBuffer(), suggestions: two,
            popoverPresented: false, dismissed: false),
            "空行不主动展开")
        XCTAssertFalse(PetAutoPanelPolicy.isVisible(
            input: typing("git s"), suggestions: [],
            popoverPresented: false, dismissed: false))
    }

    func testStalePastePopoverAndDismissalAllSuppress() {
        // 按 Tab 后影子不可信（stale）—— 含裸 Esc，同一路径。
        var stale = typing("git s")
        stale.consume(ArraySlice([0x09]))
        XCTAssertFalse(PetAutoPanelPolicy.isVisible(
            input: stale, suggestions: two,
            popoverPresented: false, dismissed: false))

        var pasting = PetInputBuffer()
        pasting.consume(ArraySlice(Array("\u{1B}[200~".utf8)))
        XCTAssertFalse(PetAutoPanelPolicy.isVisible(
            input: pasting, suggestions: two,
            popoverPresented: false, dismissed: false),
            "括号粘贴中不展开")

        XCTAssertFalse(PetAutoPanelPolicy.isVisible(
            input: typing("git s"), suggestions: two,
            popoverPresented: true, dismissed: false),
            "完整气泡开着时让位，不叠两层")
        XCTAssertFalse(PetAutoPanelPolicy.isVisible(
            input: typing("git s"), suggestions: two,
            popoverPresented: false, dismissed: true),
            "本行被手动关过后不再弹")
    }
}

final class PetHistoryParsingTests: XCTestCase {

    func testExtendedZshFormatIsUnwrapped() {
        let raw = """
        : 1698345678:0;git status
        : 1698345690:0;open .
        """
        XCTAssertEqual(PetContextStore.parseHistory(raw), ["git status", "open ."])
    }

    func testPlainFormatIsTakenAsIs() {
        let raw = """
        ls -la
        pwd
        """
        XCTAssertEqual(PetContextStore.parseHistory(raw), ["ls -la", "pwd"])
    }

    func testContinuationLinesAreDropped() {
        let raw = """
        : 1698345678:0;git commit -m "first part \\
        second part"
        : 1698345690:0;git status
        """
        XCTAssertEqual(PetContextStore.parseHistory(raw), ["git status"],
                       "拼不起来的多行命令宁可不给")
    }

    func testCommentsAreSkipped() {
        XCTAssertEqual(PetContextStore.parseHistory("# note\npwd"), ["pwd"])
    }
}
