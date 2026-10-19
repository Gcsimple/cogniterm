import Foundation

/// 一条历史会话的**可读摘要**。
///
/// 为什么不在 App 里直接调 ACP 的 `session/list`：
///   `dsh-acp/lib/index.js` 的 `listSessions` 内部**持有** `header.createdAt`、还按它
///   倒序排好，但响应里 `page.map(({ sessionId, cwd }) => …)` 把时间和标题裁掉了。
///   于是 UI 只能显示 `会话 <uuid 前 8 位>`——用户既认不出是哪次对话，也没法按时间排序。
///
///   而 dsh 把这两样都落在了本地明文里：
///     - `storages/session_projcache/sessions/<id>.json` → `record.identity.createdAt`、
///       `record.rows.title.val`（就是首条用户消息，dsh 自己生成的本地标题）、
///       `record.rows.titleInput.val.count`（用户消息数）
///     - 轨迹文件的 mtime → 最后一次活动时间
///   实测本机 123 个会话 **123 个都有 projcache**，所以这条路是可靠的，且不需要
///   任何 LLM 调用（我们关掉了 session-title-llm，标题照样有）。
public struct SessionSummary: Identifiable, Equatable, Sendable {
    public let sessionId: String
    /// dsh 自己写的标题（= 首条用户消息）。空会话为 nil。
    public let title: String?
    public let cwd: String?
    /// 会话创建时间（projcache 的 `identity.createdAt`，毫秒 → Date）。
    public let createdAt: Date?
    /// 最后一次活动（轨迹文件 mtime）。比 createdAt 更能回答"最近在用哪个"。
    public let lastActivity: Date?
    /// 用户消息条数。0 = 空会话（每次 handshake 顺手建的那种）。
    public let userMessageCount: Int
    /// 轨迹文件路径（`session.v<N>.jsonl.zstd`）。预览时解压它。
    public let trajectory: URL?
    /// 会话目录（`sessions/<cwd 编码>/<sessionId>/`）。删除时整个目录进废纸篓。
    public let sessionDirectory: URL

    public var id: String { sessionId }

    /// 空会话：建了但从未说过话。侧栏默认不列——它们占位且点进去什么都没有。
    public var isBlank: Bool { userMessageCount == 0 }

    /// 展示标题。**绝不回落成 UUID**：那正是这轮要修的问题。
    ///
    /// 无标题但确实有内容时，用「未命名会话 · N 轮」——它至少能让人判断"这是个
    /// 真有东西的会话"，而不是一串看起来像哈希的字符。
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return isBlank ? "空会话" : "未命名会话 · \(userMessageCount) 轮"
    }

    public init(sessionId: String,
                title: String?,
                cwd: String?,
                createdAt: Date?,
                lastActivity: Date?,
                userMessageCount: Int,
                trajectory: URL?,
                sessionDirectory: URL) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.userMessageCount = userMessageCount
        self.trajectory = trajectory
        self.sessionDirectory = sessionDirectory
    }
}

/// 扫描 dsh 的落盘目录，产出 `SessionSummary` 列表。
///
/// 布局（实测 dsh 0.2，macOS）：
/// ```
/// <DSH_HOME>/sessions/<cwd 编码>/<sessionId>/session.v4.jsonl.zstd
/// <DSH_HOME>/storages/session_projcache/sessions/<sessionId>.json
/// ```
/// 目录名是 cwd 把 `/` 换成 `-` 的结果（`--Users-Admin-CogniTerm--`），
/// 但目录名本身**不可逆**（路径里的 `-` 会混进来），所以 cwd 只从 projcache 读。
public enum SessionIndex {

    /// 扫描结果。fail-soft：任何读不懂的东西都跳过，绝不让历史列表把 App 带崩。
    public static func load(dshHome: URL, includeBlank: Bool = false) -> [SessionSummary] {
        let sessionsRoot = dshHome.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = dshHome
            .appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)

        let fm = FileManager.default
        guard let workspaceDirs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var summaries: [SessionSummary] = []
        for workspaceDir in workspaceDirs {
            guard let sessionDirs = try? fm.contentsOfDirectory(
                at: workspaceDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for dir in sessionDirs {
                guard let summary = summarize(sessionDir: dir, cacheRoot: cacheRoot) else { continue }
                if !includeBlank && summary.isBlank { continue }
                summaries.append(summary)
            }
        }

        return summaries.sorted { left, right in
            let l = left.lastActivity ?? left.createdAt ?? .distantPast
            let r = right.lastActivity ?? right.createdAt ?? .distantPast
            if l != r { return l > r }
            return left.sessionId < right.sessionId
        }
    }

    /// 单个会话目录 → 摘要。缺轨迹或缺 projcache 时按能拿到的部分降级。
    static func summarize(sessionDir: URL, cacheRoot: URL) -> SessionSummary? {
        let sessionId = sessionDir.lastPathComponent
        guard !sessionId.isEmpty, !sessionId.hasPrefix(".") else { return nil }

        let trajectory = newestTrajectory(in: sessionDir)
        let cache = cacheRoot.appendingPathComponent("\(sessionId).json")
        let meta = ProjectionCache.read(at: cache)

        // 既没有轨迹也没有投影 → 不是会话目录（可能是别的杂物）。
        guard trajectory != nil || meta != nil else { return nil }

        let mtime = trajectory
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let size = trajectory.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0

        // 消息条数：projcache 为准；读不到时用轨迹大小兜底（只有 header 的文件约 150 字节）。
        let count = meta?.userMessageCount ?? (size > 400 ? 1 : 0)

        return SessionSummary(
            sessionId: sessionId,
            title: meta?.title,
            cwd: meta?.cwd,
            createdAt: meta?.createdAt,
            lastActivity: mtime ?? meta?.createdAt,
            userMessageCount: count,
            trajectory: trajectory,
            sessionDirectory: sessionDir
        )
    }

    /// `session.v<N>.jsonl.zstd`；dsh 升级格式后可能同时存在多个版本，取最新的那个。
    private static func newestTrajectory(in sessionDir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files
            .filter { name in
                let n = name.lastPathComponent
                return n.hasPrefix("session.v") && n.hasSuffix(".jsonl.zstd")
            }
            .max { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
    }
}

/// 会话的**删除**：移入废纸篓，而不是直接抹掉。
///
/// 为什么不做 `removeItem`：轨迹是用户自己的对话记录，删掉无法再生；而 dsh 的列表
/// 完全按目录扫描，**移走就等于"列表里消失"**，不需要我们额外记账。放进废纸篓还能
/// 反悔——这正是 macOS 上"删一个文档"的默认语义。
public enum SessionStore {

    public enum Failure: LocalizedError, Equatable {
        /// summary 的目录不在 `<dshHome>/sessions/` 之下，或 id 对不上。
        case outsideSessionsRoot(String)

        public var errorDescription: String? {
            switch self {
            case .outsideSessionsRoot(let path):
                return "拒绝删除 \(path)：它不在会话目录里"
            }
        }
    }

    /// 把会话目录 + 它的投影缓存一起移入废纸篓，返回被移动后的新位置。
    ///
    /// 只认 `<dshHome>/sessions/<cwd 编码>/<sessionId>` 这一层形状，且目录名必须等于
    /// sessionId：`SessionSummary` 将来若多出别的来源（导入、备份），也不会误删到别处。
    ///
    /// `move` 只为了让测试不往**真实的**废纸篓里扔东西；生产路径永远是 `trashItem`。
    @discardableResult
    public static func trash(_ summary: SessionSummary,
                             dshHome: URL,
                             move: (URL) throws -> URL = SessionStore.moveToTrash) throws -> [URL] {
        var trashed: [URL] = []
        for url in try trashTargets(for: summary, dshHome: dshHome) {
            trashed.append(try move(url))
        }
        return trashed
    }

    /// 删除会动到的路径（会话目录在前，投影缓存按存在与否跟在后面）。
    /// 校验也在这里：拿不到合法路径就直接抛，不会「删一半」。
    public static func trashTargets(for summary: SessionSummary, dshHome: URL) throws -> [URL] {
        let fm = FileManager.default
        let root = dshHome
            .appendingPathComponent("sessions", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let dir = summary.sessionDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL

        // 三条都必须成立：在 sessions 根之下（不含根本身）、目录名就是 sessionId、
        // 且真的存在。任一条不成立都说明这份 summary 不可信。
        guard dir.path.hasPrefix(root.path + "/"),
              dir.lastPathComponent == summary.sessionId,
              fm.fileExists(atPath: dir.path) else {
            throw Failure.outsideSessionsRoot(dir.path)
        }

        var targets = [dir]

        // 投影缓存是可重建的派生数据，但留着它会变成"没有目录的孤儿"——顺手带走。
        let cache = dshHome
            .appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
            .appendingPathComponent("\(summary.sessionId).json")
        if fm.fileExists(atPath: cache.path) { targets.append(cache) }
        return targets
    }

    /// 生产环境唯一允许的删除方式：进废纸篓（`~/.Trash`），可反悔。
    public static func moveToTrash(_ url: URL) throws -> URL {
        // 这个 API 的出参是 `AutoreleasingUnsafeMutablePointer<NSURL?>`，不是 `URL`。
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        return (landed as URL?) ?? url
    }
}

/// dsh 投影缓存里我们关心的几个字段。
/// 用 `JSONSerialization` 而不是 `Codable`：这是 dsh 的**内部**格式（`version: 7`），
/// 字段会随版本增减；强类型解码一改就整份失败，而这只是列表的装饰性数据。
enum ProjectionCache {
    struct Meta: Equatable {
        var title: String?
        var cwd: String?
        var createdAt: Date?
        var userMessageCount: Int
    }

    static func read(at url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any] else { return nil }

        let identity = record["identity"] as? [String: Any]
        let rows = record["rows"] as? [String: Any]

        var title: String?
        if let row = rows?["title"] as? [String: Any],
           let value = row["val"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmed.isEmpty ? nil : trimmed
        }

        var count = 0
        if let row = rows?["titleInput"] as? [String: Any],
           let value = row["val"] as? [String: Any] {
            // `count` 是用户消息条数；缺失时看 `first.text` 是否存在。
            if let n = value["count"] as? Int {
                count = n
            } else if let first = value["first"] as? [String: Any],
                      let text = first["text"] as? String,
                      !text.isEmpty {
                count = 1
            }
        }

        var createdAt: Date?
        if let ms = identity?["createdAt"] as? Double, ms > 0 {
            createdAt = Date(timeIntervalSince1970: ms / 1000)
        }

        let cwd = identity?["cwd"] as? String

        return Meta(title: title, cwd: cwd, createdAt: createdAt, userMessageCount: count)
    }
}
