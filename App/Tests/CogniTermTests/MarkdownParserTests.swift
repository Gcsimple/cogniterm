import XCTest
@testable import CogniTerm

/// Markdown 解析器的回归。
///
/// 判据全部落在 `parse` 的返回值上（纯函数，不需要窗口、shell 或 agent）——
/// 这是本仓库对「视图层逻辑」的一贯要求：能测的部分必须能脱离 UI 测。
final class MarkdownParserTests: XCTestCase {

    // MARK: - 代码块

    /// fence 内部的 `#`、`-` 必须原样保留。
    /// 这是最容易写错的边界：先识别块的实现会在代码里认出标题和列表，
    /// 把一段 shell 脚本拆成一堆段落。
    func testFenceKeepsInnerMarkersLiteral() {
        let text = """
        先跑这个：

        ```bash
        # 这里的井号是注释，不是标题
        - 这里的横杠是参数，不是列表
        npm run build
        ```
        """
        let blocks = MarkdownParser.parse(text)

        XCTAssertEqual(blocks.count, 2)
        guard case .paragraph = blocks[0] else { return XCTFail("第一块应该是段落") }
        guard case .codeBlock(let language, let code) = blocks[1] else {
            return XCTFail("第二块应该是代码块")
        }
        XCTAssertEqual(language, "bash")
        XCTAssertEqual(code, "# 这里的井号是注释，不是标题\n- 这里的横杠是参数，不是列表\nnpm run build")
    }

    /// 模型漏写收尾的三个反引号时，内容不能被吞掉。
    func testUnclosedFenceStillEmitsCode() {
        let blocks = MarkdownParser.parse("```sh\nls -la")
        XCTAssertEqual(blocks, [.codeBlock(language: "sh", code: "ls -la")])
    }

    /// 语言标记只取第一个词（`bash title=x` → `bash`）。
    func testFenceLanguageTakesFirstWordOnly() {
        let blocks = MarkdownParser.parse("```python title=\"a.py\"\nprint(1)\n```")
        guard case .codeBlock(let language, _) = blocks.first else {
            return XCTFail("应该是代码块")
        }
        XCTAssertEqual(language, "python")
    }

    // MARK: - 段落 / 列表

    func testParagraphJoinsSoftWrappedLines() {
        let blocks = MarkdownParser.parse("第一行\n第二行\n\n另一段")
        XCTAssertEqual(blocks.count, 2)
        // 软换行保留成 \n：技术内容里换行本身带信息（并列项、参数表）。
        XCTAssertEqual(blocks[0], .paragraph([.text("第一行\n第二行")]))
    }

    func testBulletsAndNumberedLists() {
        let blocks = MarkdownParser.parse("""
        - 第一条
        - 第二条

        1. 甲
        2. 乙
        """)

        XCTAssertEqual(blocks.count, 2)
        guard case .bullets(let bullets) = blocks[0] else { return XCTFail("应为无序列表") }
        XCTAssertEqual(bullets.count, 2)
        XCTAssertEqual(bullets[0], [.text("第一条")])
        guard case .numbered(let start, let items) = blocks[1] else { return XCTFail("应为有序列表") }
        XCTAssertEqual(start, 1)
        XCTAssertEqual(items.count, 2)
    }

    /// 编号列表保留起始数字（模型常从 2 续写一个列表）。
    func testNumberedListKeepsStartValue() {
        let blocks = MarkdownParser.parse("2. 第二步\n3. 第三步")
        guard case .numbered(let start, let items) = blocks.first else {
            return XCTFail("应为有序列表")
        }
        XCTAssertEqual(start, 2)
        XCTAssertEqual(items.count, 2)
    }

    func testHeadingBecomesBoldParagraph() {
        XCTAssertEqual(MarkdownParser.parse("### 结论"),
                       [.paragraph([.bold("结论")])])
        // 没有空格的 `##foo` 不是标题（CommonMark 同款规则）
        XCTAssertEqual(MarkdownParser.parse("##foo"), [.paragraph([.text("##foo")])])
    }

    func testHorizontalRuleIsDropped() {
        XCTAssertEqual(MarkdownParser.parse("上\n\n---\n\n下").count, 2)
    }

    // MARK: - 行内

    func testInlineCodeBoldAndLink() {
        let runs = MarkdownParser.parseInline("跑 `make` 然后 **立刻** 看 [文档](https://example.com/x)")
        XCTAssertEqual(runs, [
            .text("跑 "),
            .code("make"),
            .text(" 然后 "),
            .bold("立刻"),
            .text(" 看 "),
            .link(text: "文档", href: "https://example.com/x"),
        ])
    }

    /// 行内 code 里的 `*` 不当粗体处理——否则 `` `git checkout *` `` 会被吃掉星号。
    func testInlineCodeShieldsAsterisks() {
        let runs = MarkdownParser.parseInline("`a * b`")
        XCTAssertEqual(runs, [.code("a * b")])
    }

    func testBarePathAndURLAreTagged() {
        let runs = MarkdownParser.parseInline("改 App/Sources/Views/TerminalPaneView.swift，见 https://example.com/a。")
        XCTAssertEqual(runs, [
            .text("改 "),
            .path("App/Sources/Views/TerminalPaneView.swift"),
            .text("，见 "),
            .link(text: "https://example.com/a", href: "https://example.com/a"),
            .text("。"),
        ])
    }

    /// 误判比不识别更吵：这些都不该被当成路径。
    func testNonPathsAreNotTagged() {
        for token in ["1/2", "a/b", "and/or", "SwiftUI", "v0.1.0"] {
            XCTAssertFalse(MarkdownParser.looksLikePath(token), "\(token) 不该被认成路径")
        }
        XCTAssertTrue(MarkdownParser.looksLikePath("~/x"))
        XCTAssertTrue(MarkdownParser.looksLikePath("./run.sh"))
        XCTAssertTrue(MarkdownParser.looksLikePath("README.md"))
        XCTAssertFalse(MarkdownParser.looksLikePath("http://x.com/a.json"))
    }

    // MARK: - 真实样例

    /// 一段典型的 agent 回复：标题 + 说明 + 步骤 + 命令。
    func testRealisticAgentReplyKeepsStructure() {
        let text = """
        问题在 `TerminalTabBar.swift`：切换只有点击。

        ### 改法

        1. 在菜单里加 ⌘1…⌘9
        2. 用 `sessions.activateTab(at:)` 落地

        ```swift
        Button("标签 \\(index + 1)") { sessions.activateTab(at: index) }
        ```

        完了。
        """
        let blocks = MarkdownParser.parse(text)

        // 段落 / 标题 / 有序列表 / 代码块 / 段落
        XCTAssertEqual(blocks.count, 5)
        guard case .paragraph = blocks[0] else { return XCTFail("0 段落") }
        XCTAssertEqual(blocks[1], .paragraph([.bold("改法")]))
        guard case .numbered(let start, let items) = blocks[2] else { return XCTFail("2 有序列表") }
        XCTAssertEqual(start, 1)
        XCTAssertEqual(items.count, 2)
        guard case .codeBlock(let language, let code) = blocks[3] else { return XCTFail("3 代码块") }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("activateTab"))
        guard case .paragraph = blocks[4] else { return XCTFail("4 段落") }
    }
}
