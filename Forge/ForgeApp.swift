import SwiftUI

@main
@MainActor
struct ForgeApp: App {
    @State private var store = ForgeStore()
    @State private var downloads = DownloadManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                .environment(store)
                .environment(downloads)
                .tint(.blue)
                .task(id: scenePhase) {
                    if scenePhase == .active { await store.refresh() }
                }
        }
    }

    @ViewBuilder private var root: some View {
        #if DEBUG
        // Simulator visual checks use real public GitHub pages; Release builds omit this entry point.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--forge-preview-url"),
           ProcessInfo.processInfo.arguments.count > index + 1,
           let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]), GitHubRoute(url) != nil {
            NavigationStack { GitHubDestination(url: url) }.inAppLinks()
        } else { HomeView() }
        #else
        HomeView()
        #endif
    }
}
