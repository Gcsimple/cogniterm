import SwiftUI
import TerminalCore

/// 远程目录选择器。
///
/// ## 为什么不是 `NSOpenPanel`
///
/// `NSOpenPanel` 背后是**本机**的 Finder 与卷列表。SSH 会话里要选的是远端
/// 文件系统上的目录，两者没有任何对应关系——旧实现让用户在这里挑一个本地
/// 目录，然后把"agent 工作区"设成它，于是 agent 以为自己在 `/Users/…`，
/// 命令却跑在远端的登录目录里。
///
/// 这里换成一个**远端语义**的选择器：路径输入 + 「浏览」按需列举子目录。
/// 列举走独立的一次性 ssh（`RemoteDirectoryBrowser`），不碰用户终端，
/// 所以就算远端正在跑构建也不会被打扰。
///
/// ## 为什么默认是手工输入而不是自动探测
///
/// 远端 shell 的当前目录只有两种来源：OSC 7（需远端 shell 配置，默认不发）
/// 或注入 `pwd`（会往用户屏幕上打字，可能打进 vim/密码提示）。两者都不该
/// 自动做。所以默认值来自"用户上次选的"或 `~`，其余交给显式输入与浏览。
struct RemoteDirectorySheet: View {
    /// 要设定目录的会话（决定连哪台机器、以及确认后由谁去 `cd`）。
    @ObservedObject var session: TerminalSession

    @Environment(\.dismiss) private var dismiss

    /// 输入框内容。可以是 `~` / `~/xxx` / 绝对路径。
    @State private var path: String
    /// 最近一次列举结果（含远端 `pwd` 解开的绝对路径）。
    @State private var listing: RemoteDirectoryListing?
    @State private var isLoading = false
    @State private var errorText: String?
    /// 首次出现时自动列举一次；之后只在用户点「浏览」/ 点子目录时列。
    @State private var didInitialList = false

    init(session: TerminalSession) {
        self.session = session
        _path = State(initialValue: session.remoteWorkingDirectory ?? "~")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 8) {
                TextField("~/project 或 /opt/app", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { browse(path) }
                Button("浏览") { browse(path) }
                    .disabled(isLoading)
            }

            directoryList

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("agent 的终端命令会在这个目录里执行（本 App 会先 cd 过去）。"
                 + "文件工具（read_file / glob）仍只作用于本地工作区。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            footer
        }
        .padding(18)
        .frame(width: 520)
        .task {
            guard !didInitialList else { return }
            didInitialList = true
            browse(path)
        }
    }

    // MARK: - 分区

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("远程执行目录")
                .font(.headline)
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.caption2)
                Text(session.label)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var directoryList: some View {
        VStack(spacing: 0) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在列目录…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            } else if let listing {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if listing.path != "/" {
                            row(name: "..", systemImage: "arrow.turn.up.left") {
                                browse(parent(of: listing.path))
                            }
                            Divider()
                        }
                        ForEach(listing.directories, id: \.self) { name in
                            row(name: name, systemImage: "folder") {
                                browse(join(listing.path, name))
                            }
                        }
                        if listing.directories.isEmpty {
                            Text("（没有子目录）")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .frame(height: 220)
            } else {
                Text("点「浏览」列出子目录，或直接在输入框里写路径。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func row(name: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            if let listing {
                Text(listing.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            // 用了「浏览」就以远端 pwd 解开的绝对路径为准：`~` 与相对路径
            // 一旦存进配置，下次连上时可能指向别处。
            Button("用这个目录") {
                let resolved = listing?.path ?? path.trimmingCharacters(in: .whitespacesAndNewlines)
                session.setRemoteWorkingDirectory(resolved)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - 动作

    private func browse(_ target: String) {
        let query = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isLoading = true
        errorText = nil
        session.listRemoteDirectories(at: query) { result in
            isLoading = false
            switch result {
            case .success(let value):
                listing = value
                // 输入框跟着走到解开的绝对路径：用户下一步看到的路径
                // 与真正会被保存的路径必须是同一个。
                path = value.path
            case .failure(let error):
                listing = nil
                errorText = error.errorDescription ?? "\(error)"
            }
        }
    }

    private func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func join(_ base: String, _ name: String) -> String {
        (base as NSString).appendingPathComponent(name)
    }
}
