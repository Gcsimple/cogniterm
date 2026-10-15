import SwiftUI
import SwiftData
import Persistence

@main
struct CogniTermApp: App {
    let container: ModelContainer

    init() {
        // 生产库不可用时退化为内存库，保证 UI 仍可启动（并在诊断中体现）。
        if let production = try? PersistenceStack.defaultContainer() {
            container = production
        } else {
            // swiftlint:disable:next force_try
            container = try! PersistenceStack.inMemoryContainer()
        }
    }

    var body: some Scene {
        WindowGroup("CogniTerm") {
            MainSplitView()
                .modelContainer(container)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .modelContainer(container)
                .frame(width: 480, height: 420)
        }
    }
}
