import SwiftUI
import WebKit
import UniformTypeIdentifiers

@MainActor
struct RichReadmeView: UIViewRepresentable {
    let document: ReadmeDocument
    @Binding var height: CGFloat
    @Environment(ForgeStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(document: document, client: store.client, height: $height) { openURL($0) } }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "forge-readme")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        context.coordinator.observation = view.scrollView.observe(\.contentSize, options: [.new]) { scroll, _ in
            DispatchQueue.main.async { if abs(context.coordinator.height.wrappedValue - scroll.contentSize.height) > 1 { context.coordinator.height.wrappedValue = max(80, scroll.contentSize.height) } }
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let html = document.page(dark: scheme == .dark)
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html; view.loadHTMLString(html, baseURL: document.baseURL)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); coordinator.tasks.values.forEach { $0.cancel() }; coordinator.observation = nil }

    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        let document: ReadmeDocument
        let client: GitHubClient
        let height: Binding<CGFloat>
        let open: (URL) -> Void
        var loaded = ""
        var observation: NSKeyValueObservation?
        var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        init(document: ReadmeDocument, client: GitHubClient, height: Binding<CGFloat>, open: @escaping (URL) -> Void) { self.document = document; self.client = client; self.height = height; self.open = open }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                if url.fragment != nil, url.path == document.baseURL.path { decisionHandler(.allow); return }
                if url.scheme == "https", url.user == nil { open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(url == document.baseURL || url.scheme == "about" ? .allow : .cancel) }
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let key = ObjectIdentifier(urlSchemeTask)
            tasks[key] = Task { @MainActor in
                defer { tasks[key] = nil }
                do {
                    guard let url = urlSchemeTask.request.url, document.imagePath(url) != nil else { throw GitHubError("Invalid image path.") }
                    let data = try await client.readmeImage(url, document: document)
                    guard !Task.isCancelled else { return }
                    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
                    urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                } catch { if !Task.isCancelled { urlSchemeTask.didFailWithError(error) } }
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
    }
}

@MainActor
struct ReadmeCard: View {
    let repository: Repository
    let branch: RepositoryBranch
    var canEdit = true
    var onEdited: () -> Void = {}
    @Environment(ForgeStore.self) private var store
    @State private var file: RepositoryFile?
    @State private var document: ReadmeDocument?
    @State private var error: String?
    @State private var height: CGFloat = 80
    @State private var editingText: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if canEdit, store.hasToken, let file { Button { Task { do { editingText = try await store.client.codeText(in: repository, file: file) } catch { self.error = error.localizedDescription } } } label: { Label("Edit", systemImage: "pencil") } }
                Spacer(); Label(file?.name ?? "README", systemImage: "doc.richtext").font(.headline)
            }.padding(16)
            Divider()
            if let document { RichReadmeView(document: document, height: $height).id(branch.commit.sha).frame(height: height) }
            else if let error { Text(error).font(.footnote).foregroundStyle(.secondary).padding(); Button("Retry") { Task { await load() } }.padding(.horizontal) }
            else { ProgressView("Loading README…").padding() }
            if document != nil, let error { ErrorNotice(message: error).padding() }
        }.task(id: "\(store.account):\(branch.commit.sha)") { await load() }
        .sheet(isPresented: Binding(get: { editingText != nil }, set: { if !$0 { editingText = nil } })) {
            if let file, let editingText { FileEditor(repository: repository, file: file, branch: branch.name, initialText: editingText) { _, _ in self.editingText = nil; onEdited() } }
        }
    }
    private func load() async {
        error = nil; document = nil; file = nil; height = 80
        do { let (file, document) = try await store.client.readme(in: repository, sha: branch.commit.sha); guard !Task.isCancelled else { return }; self.file = file; self.document = document }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
extension View {
    @ViewBuilder func readmeSectionLayout() -> some View {
        let section = self.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        if #available(iOS 26.0, *) { section.listSectionMargins(.horizontal, 0) }
        else { section }
    }
}
