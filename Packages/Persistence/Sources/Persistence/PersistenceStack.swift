import Foundation
import SwiftData

@available(macOS 14.0, *)
public enum PersistenceStack {

    public static var schema: Schema {
        Schema([
            Workspace.self,
            SessionRecord.self,
            ApprovalRuleRecord.self,
            AppSettings.self,
            SSHBookmark.self,
        ])
    }

    /// 测试与预览用：纯内存，不落盘。
    public static func inMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// 生产：Application Support/CogniTerm/default.store。
    public static func defaultContainer() throws -> ModelContainer {
        let directory = try applicationSupportDirectory()
        let configuration = ModelConfiguration(schema: schema,
                                               url: directory.appendingPathComponent("default.store"))
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("CogniTerm", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
