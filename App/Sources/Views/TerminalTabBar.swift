import SwiftUI
import SwiftData
import TerminalCore
import Persistence

/// 终端面板顶部的会话标签栏。
///
/// 为什么终端会话从侧栏搬到这里：侧栏是**导航**（我去哪儿），终端会话是
/// **操作对象**（我在哪个 shell 里敲命令）。旧版把两者塞进同一个列表，侧栏
/// 要背 4 段内容，「终端」和「SSH 书签」还被拆成两个概念（书签 = 还没开的会话）。
/// 搬到终端面板上方后，切换成本从「抬头到侧栏找列表」变成「顺手点标签」，
/// 而且书签天然就是「＋」里的候选项——一个动作只有一个位置。
struct TerminalTabBar: View {
    @ObservedObject var sessions: SessionManager
    /// 新建 SSH 会话（表单在 MainSplitView 上，这里只发信号）。
    var onNewSSH: () -> Void
    /// 书签参数不合法等用户可见错误（写进对话流，而不是静默失败）。
    var onError: (String) -> Void = { _ in }

    @Query(sort: \SSHBookmark.lastUsedAt, order: .reverse) private var bookmarks: [SSHBookmark]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessions.sessions) { session in
                        TerminalTabItem(
                            session: session,
                            isActive: session.id == sessions.activeSessionID,
                            onSelect: { sessions.activate(session.id) },
                            onClose: { sessions.close(session.id) }
                        )
                    }
                }
                .padding(.horizontal, 6)
            }

            Menu {
                if bookmarks.isEmpty {
                    Text("还没有 SSH 书签")
                } else {
                    Section("已保存") {
                        ForEach(bookmarks) { bookmark in
                            Button(bookmark.name) { open(bookmark) }
                        }
                    }
                    Section {
                        ForEach(bookmarks) { bookmark in
                            Button("删除书签「\(bookmark.name)」", role: .destructive) {
                                modelContext.delete(bookmark)
                                try? modelContext.save()
                            }
                        }
                    }
                }
                Divider()
                Button("新建 SSH 会话…", action: onNewSSH)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("新建 SSH 会话 / 打开书签")

            Spacer(minLength: 6)
        }
        .frame(height: 26)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func open(_ bookmark: SSHBookmark) {
        let target = SSHTarget(
            host: bookmark.host,
            port: bookmark.port,
            username: bookmark.username.isEmpty ? nil : bookmark.username,
            identityFilePath: bookmark.identityFilePath,
            jumpHost: bookmark.jumpHost
        )
        guard target.isValid else {
            // 书签可能是旧版本写的（校验规则变过）。静默失败等于让人对着没反应的
            // 菜单发呆，所以把原因写进对话流。
            onError("书签「\(bookmark.name)」参数不合法："
                    + target.validationErrors().joined(separator: "；"))
            return
        }
        bookmark.lastUsedAt = Date()
        try? modelContext.save()
        sessions.openSSHSession(
            target: target,
            label: bookmark.name,
            root: FileManager.default.homeDirectoryForCurrentUser
        )
    }
}

/// 单个标签。
///
/// 独立成 view 的唯一原因是**订阅粒度**：会话状态是各会话自己的 `@Published`，
/// 而 SessionManager 只转发活跃会话的 `objectWillChange`。写在外层方法里，
/// 后台正在连接的 SSH 标签状态点会一直停在旧值。
private struct TerminalTabItem: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var dotColor: Color {
        switch session.status {
        case .running: return .green
        case .exited: return .orange
        case .failed: return .red
        case .idle: return Color.secondary.opacity(0.35)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(session.label)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)

            // 本地会话不给关闭按钮：它是 agent 的默认执行平面（关掉后
            // run_in_terminal 无处可去，而菜单与审批卡都默认它存在）。
            if session.kind == .ssh, hovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("关闭会话")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.secondary.opacity(0.25) : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(session.kind == .ssh ? "SSH：\(session.label)" : "本地 shell")
        .contextMenu {
            Button("重启", action: session.restart)
            if session.kind == .ssh {
                Button("关闭会话", role: .destructive, action: onClose)
            }
        }
    }
}
