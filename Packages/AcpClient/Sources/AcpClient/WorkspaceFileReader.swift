import Foundation

/// fs/read_text_file 的客户端实现：workspace 边界内读文本文件。
///
/// 安全约束（fail-closed）：
/// - 只接受绝对路径（~ 展开后判定），拒绝相对路径；
/// - 解析符号链接后仍须位于 workspaceRoot 之内，挡 `..` 穿越与 symlink 越界；
/// - 超过 maxBytes 的文件拒绝读取（避免把大文件灌进模型上下文）；
/// - line/limit 为 1-based 语义，与 ACP schema 一致。
public enum FileReadError: Error, Equatable, CustomStringConvertible {
    case relativePath(String)
    case outsideWorkspace(path: String)
    case tooLarge(bytes: Int, limit: Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .relativePath(let path): return "路径必须是绝对路径：\(path)"
        case .outsideWorkspace(let path): return "路径在工作区之外：\(path)"
        case .tooLarge(let bytes, let limit): return "文件过大（\(bytes) 字节 > 上限 \(limit)）"
        case .unreadable(let reason): return "读取失败：\(reason)"
        }
    }
}

public struct WorkspaceFileReader: Sendable {
    public var workspaceRoot: String
    public var maxBytes: Int

    public init(workspaceRoot: String, maxBytes: Int = 1_000_000) {
        self.workspaceRoot = workspaceRoot
        self.maxBytes = maxBytes
    }

    public func read(path: String, line: Int? = nil, limit: Int? = nil) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw FileReadError.relativePath(path)
        }
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        let root = URL(fileURLWithPath: workspaceRoot).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == root || resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw FileReadError.outsideWorkspace(path: path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        } catch {
            throw FileReadError.unreadable(error.localizedDescription)
        }
        if data.count > maxBytes {
            throw FileReadError.tooLarge(bytes: data.count, limit: maxBytes)
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw FileReadError.unreadable("文件不是 UTF-8 文本")
        }

        if line != nil || limit != nil {
            var lines = text.components(separatedBy: "\n")
            // 尾随换行会产生一个空末行；切片语义下先去掉，避免 limit 少一行。
            if lines.last == "" { lines.removeLast() }
            let start = max((line ?? 1) - 1, 0)
            guard start < lines.count else { return "" }
            let end = limit.map { min(start + $0, lines.count) } ?? lines.count
            text = lines[start..<end].joined(separator: "\n")
        }
        return text
    }
}
