import SwiftUI
import AppKit
import PolicyEngine

/// 助手消息的渲染：段落 / 代码块 / 列表，代码块带动作条。
///
/// 排版取向是**克制**：正文保持裸文本（只是把 markdown 记号去掉了），
/// 只有代码块加边框和动作，列表加圆点。理由——这个对话区是手机屏幕上
/// 一段工作日志，不是文档站；上全套标题层级和引用样式会把真正要看的东西淹掉。
struct MarkdownMessageView: View {
    let text: String
    /// 传给 `RiskEvaluator` 判越界用（命令里出现工作区之外的绝对路径要升级）。
    var workspaceRoot: String? = nil
    /// 「运行」的出口。由上层注入——它同时负责捕获输出并回喂 agent。
    var onRunCommand: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let runs):
            Text(inline(runs))
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(let language, let code):
            MarkdownCodeBlockView(language: language,
                                  code: code,
                                  workspaceRoot: workspaceRoot,
                                  onRun: onRunCommand)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, runs in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(.body).foregroundStyle(.tertiary)
                        Text(inline(runs)).font(.body).textSelection(.enabled)
                    }
                }
            }

        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, runs in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + offset).")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(inline(runs)).font(.body).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func inline(_ runs: [MarkdownInline]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            switch run {
            case .text(let value):
                result += AttributedString(value)

            case .code(let value):
                var piece = AttributedString(value)
                piece.font = .system(.body, design: .monospaced)
                piece.backgroundColor = Color.secondary.opacity(0.14)
                result += piece

            case .bold(let value):
                var piece = AttributedString(value)
                piece.font = .body.bold()
                result += piece

            case .link(let label, let href):
                var piece = AttributedString(label)
                if let url = URL(string: href) { piece.link = url }
                piece.foregroundColor = .accentColor
                piece.underlineStyle = .single
                result += piece

            case .path(let value):
                // 只做视觉强调，**不做点击**：路径大多在远端或压缩包内，
                // 点了打不开比没有链接更糟（"假承诺"比"没承诺"伤人）。
                var piece = AttributedString(value)
                piece.font = .system(.callout, design: .monospaced)
                piece.foregroundColor = .accentColor
                result += piece
            }
        }
        return result
    }
}

/// 代码块：语言标签 + 复制 / 插入 / 运行。
///
/// 三个动作的语义差别是刻意设计的：
/// - **复制**：给「我要粘到别处」的场景，不动终端。
/// - **插入**：把命令键入终端但**不回车**，用户可以改了再按 ↵。
///   这是「运行」之外的第二道人工闸，且不花额外点击。
/// - **运行**：先过 `RiskEvaluator`。高风险命令**不直接执行**，
///   而是在块下方展开一条确认条——模型说的话不能当成用户授权。
private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    let workspaceRoot: String?
    let onRun: ((String) -> Void)?

    @State private var confirming = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 260)

            if confirming, let command = runnable {
                confirmBar(command)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(language ?? "code")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            action("复制", systemImage: copied ? "checkmark" : "doc.on.doc", copying: copied) {
                copy()
            }
            action("插入", systemImage: "arrow.right.to.line") { insert() }
            if runnable != nil {
                action("运行", systemImage: "play.fill") { requestRun() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func action(_ title: String,
                        systemImage: String,
                        copying: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(copying ? "已复制" : title, systemImage: systemImage)
                .font(.caption2)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copying ? Color.accentColor : Color.secondary)
    }

    private func confirmBar(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("要在 \(targetDescription) 执行这条命令")
                    .font(.caption2)
                if let reasons = assessment?.reasons, !reasons.isEmpty {
                    Text(reasons.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button("取消") { confirming = false }
                .font(.caption2)
                .buttonStyle(.borderless)
            Button("仍要运行") {
                confirming = false
                onRun?(command)
            }
            .font(.caption2)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - 动作

    /// 只给「单行命令」提供运行入口。
    ///
    /// 多行块里通常是好几条命令或带注释的脚本，一次性塞进 PTY 等于
    /// 用户没看过就批量执行；而逐行拆开又猜不准哪几行该一起跑。
    /// 所以多行只给复制 / 插入——把决定权明确交回给人。
    private var runnable: String? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
        guard lines.count == 1 else { return nil }
        return lines[0]
    }

    private var assessment: RiskAssessment? {
        guard let command = runnable else { return nil }
        return RiskEvaluator.assess(
            CommandInvocation(tool: "terminal", command: command, workspaceRoot: workspaceRoot)
        )
    }

    private var targetDescription: String {
        SessionManager.shared.activeSession.commandTargetDescription
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    /// 注入活跃会话（本地或 SSH 一致）——与 MCP `run_in_terminal` 同一个执行平面。
    private func insert() {
        SessionManager.shared.activeSession.insertCommand(code)
    }

    private func requestRun() {
        guard let command = runnable else { return }
        if let assessment, assessment.needsHumanApproval {
            confirming.toggle()     // 高风险：展开确认条，再点一次才执行
            return
        }
        onRun?(command)
    }
}
