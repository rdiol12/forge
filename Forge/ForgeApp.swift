import SwiftUI

@main
@MainActor
struct ForgeApp: App {
    @UIApplicationDelegateAdaptor(ForgeAppDelegate.self) private var appDelegate
    @State private var store = ForgeStore()
    @State private var downloads = DownloadManager.shared
    #if DEBUG
    @State private var previewHeight: CGFloat = 80
    @State private var downloadCheckStarted = false
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                .environment(store)
                .environment(downloads)
                .tint(.blue)
                .task(id: scenePhase) {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--forge-preview-url") || ProcessInfo.processInfo.arguments.contains("--forge-preview-code") || ProcessInfo.processInfo.arguments.contains("--forge-preview-readme") || ProcessInfo.processInfo.arguments.contains("--forge-check-downloads") { return }
                    #endif
                    if scenePhase == .active { await store.refresh() }
                }
        }
    }

    @ViewBuilder private var root: some View {
        #if DEBUG
        // Simulator visual checks use real public GitHub pages; Release builds omit this entry point.
        if ProcessInfo.processInfo.arguments.contains("--forge-check-downloads") {
            NavigationStack { DownloadsView() }.task {
                guard !downloadCheckStarted else { return }
                downloadCheckStarted = true
                await downloads.checkReleaseDownload()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--forge-preview-readme"),
           let document = try? ReadmeDocument(html: "<h1>README rendering check</h1><p>Image, table, code and links.</p><img alt='GitHub avatar' width='160' src='https://avatars.githubusercontent.com/octocat?s=256'><h2>Builds</h2><table><tr><th>Platform</th><th>Package</th></tr><tr><td>iOS</td><td>IPA</td></tr><tr><td>Android</td><td>APK</td></tr></table><pre><code>let message = &quot;Hello, Forge&quot;</code></pre><p><a href='https://github.com/octocat'>Open native profile</a></p>", repository: Repository("octocat/Hello-World"), sha: String(repeating: "a", count: 40), path: "README.md") {
            NavigationStack { List { Section { RichReadmeView(document: document, height: $previewHeight).frame(height: previewHeight) }.readmeSectionLayout() }.listStyle(.insetGrouped).navigationTitle("README check") }
        } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--forge-preview-code"), ProcessInfo.processInfo.arguments.count > index + 1,
           let text = try? String(contentsOfFile: ProcessInfo.processInfo.arguments[index + 1], encoding: .utf8) {
            NavigationStack { CodeTextView(text: text, filename: "Models.swift").navigationTitle("Models.swift").navigationBarTitleDisplayMode(.inline) }
        } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--forge-preview-url"),
           ProcessInfo.processInfo.arguments.count > index + 1,
           let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]), GitHubRoute(url) != nil {
            NavigationStack { GitHubDestination(url: url) }.inAppLinks()
        } else { HomeView() }
        #else
        HomeView()
        #endif
    }
}
