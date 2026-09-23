import SwiftUI

@main
@MainActor
struct ForgeApp: App {
    @State private var store = ForgeStore()
    @State private var downloads = DownloadManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(downloads)
                .tint(.orange)
                .task(id: scenePhase) {
                    if scenePhase == .active { await store.refresh() }
                }
        }
    }
}
