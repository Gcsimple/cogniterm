import SwiftUI
import AppKit
import TerminalCore

/// 本地 shell 桥：TerminalCore 的 PseudoTerminal → NSTextView（只读回显）。
/// 首版不引入 SwiftTerm，后续可在同一桥接层替换为 SwiftTerm 视图。
@MainActor
final class TerminalBridge: ObservableObject {
    @Published private(set) var output: String = ""
    private let pty = PseudoTerminal()
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        pty.onOutput = { [weak self] data in
            let cleaned = Self.stripANSI(String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async {
                self?.output += cleaned
            }
        }
        do {
            try pty.launch(.init(executablePath: "/bin/zsh", arguments: ["-i"]))
        } catch {
            output += "\r\n[无法启动 /bin/zsh：\(error)]\r\n"
        }
    }

    func send(_ line: String) {
        pty.write(Data((line + "\r").utf8))
    }

    func interrupt() {
        pty.sendInterrupt()
    }

    private static let ansiPattern = "\u{1b}\\[[0-9;?]*[ -/]*[@-~]"

    static func stripANSI(_ string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ansiPattern) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "")
    }
}

struct TerminalPanel: View {
    @ObservedObject var bridge: TerminalBridge
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("本地 shell（TerminalCore PTY）", systemImage: "terminal")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    bridge.interrupt()
                } label: {
                    Image(systemName: "escape")
                }
                .help("发送 Ctrl-C")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            TerminalPaneView(output: bridge.output)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                TextField("shell 输入，回车发送", text: $input)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit {
                        guard !input.isEmpty else { return }
                        bridge.send(input)
                        input = ""
                    }
                Button("发送") {
                    guard !input.isEmpty else { return }
                    bridge.send(input)
                    input = ""
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct TerminalPaneView: NSViewRepresentable {
    let output: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != output {
            textView.string = output
            textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        }
    }
}
