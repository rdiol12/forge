import SwiftUI

@MainActor
struct RepositorySettingsView: View {
    let repository: Repository
    @Environment(ForgeStore.self) private var store
    @State private var settings: RepositorySettings?
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    @State private var typedName = ""
    private var makePrivate: Bool { settings?.visibility == "public" }
    var body: some View {
        Form {
            if !store.hasToken { ConnectGitHubNotice() }
            Section("Repository visibility") {
                Text(repository.fullName).font(.headline).textSelection(.enabled)
                if let settings {
                    Label(settings.visibility.capitalized, systemImage: settings.visibility == "private" ? "lock" : "globe")
                    if settings.permissions?.admin == true, ["public", "private"].contains(settings.visibility) {
                        Text(makePrivate ? "Public forks and existing copies stay public. Some repository features may change." : "Making this repository public exposes its code, commit history, issues, and releases to everyone.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        TextField("Type \(repository.fullName) to confirm", text: $typedName).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(makePrivate ? "Make private" : "Make public", role: .destructive) { confirm = true }
                            .disabled(busy || typedName != repository.fullName)
                    } else { Text("Changing visibility requires repository administrator access. Organization rules may also restrict it.").font(.footnote).foregroundStyle(.secondary) }
                }
                if busy { ProgressView("Checking GitHub…") }
                if let error { ErrorNotice(message: error) }
                Button("Refresh permissions") { Task { await load() } }.disabled(busy)
            }
        }.navigationTitle("Repository settings").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .task { await load() }
        .confirmationDialog("Make \(repository.fullName) \(makePrivate ? "private" : "public")?", isPresented: $confirm, titleVisibility: .visible) {
            Button(makePrivate ? "Make private" : "Make public", role: .destructive) { Task { await update() } }
        } message: { Text(makePrivate ? "Existing public forks and copies remain accessible. GitHub applies your organization's visibility rules." : "Anyone will be able to read this repository and its history, including previously private content.") }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil; settings = nil
        defer { busy = false }
        do { settings = try await store.client.get("/repos/\(repository.fullName)") }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func update() async {
        guard !busy, let settings, typedName == repository.fullName else { return }; busy = true; error = nil
        do { try await store.client.setVisibility(in: repository, expected: settings.visibility, makePrivate: makePrivate); typedName = "" }
        catch { self.error = error.localizedDescription; self.settings = nil }
        busy = false
        if error == nil { await load() }
    }
}

@MainActor
struct ReadmeView: View {
    let repository: Repository
    @Environment(ForgeStore.self) private var store
    @State private var file: RepositoryFile?
    @State private var branch: String?
    @State private var error: String?
    var body: some View {
        Group {
            if let file { RepositoryFileView(repository: repository, file: file, branch: branch) }
            else if let error { ContentUnavailableView { Label("README unavailable", systemImage: "doc.text") } description: { Text(error) } actions: { Button("Retry") { Task { await load() } } } }
            else { ProgressView("Loading README…") }
        }.navigationTitle("README").task { await load() }
    }
    private func load() async {
        error = nil
        do {
            let settings: RepositorySettings = try await store.client.get("/repos/\(repository.fullName)")
            let file: RepositoryFile = try await store.client.get("/repos/\(repository.fullName)/readme", query: [URLQueryItem(name: "ref", value: settings.defaultBranch)])
            guard !Task.isCancelled else { return }; branch = settings.defaultBranch; self.file = file
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
struct FileEditor: View {
    let repository: Repository
    let file: RepositoryFile
    let branch: String
    let initialText: String
    let onSaved: (String, String) -> Void
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message = ""
    @State private var busy = false
    @State private var error: String?
    @State private var discard = false
    @State private var confirm = false
    @State private var preview = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(file.path).font(.headline); Label(branch, systemImage: "arrow.triangle.branch"); TextField("Commit message", text: $message) }.disabled(busy)
                Section {
                    Toggle("Preview Markdown", isOn: $preview)
                    if preview { MarkdownDocumentView(text: text) }
                    else { TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 300).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("File contents").disabled(busy) }
                }
                if busy { ProgressView("Saving commit…") }
                if let error { ErrorNotice(message: error) }
                Text("Saving creates a commit on this branch and can start workflows. Branch protection and Contents write permissions still apply.").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Edit \(file.name)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if text == initialText { dismiss() } else { discard = true } }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Commit") { confirm = true }.disabled(busy || text == initialText || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.interactiveDismissDisabled()
            .onAppear { text = initialText; message = "Update \(file.name)" }
            .confirmationDialog("Commit changes to \(branch)?", isPresented: $confirm, titleVisibility: .visible) { Button("Commit changes") { Task { await save() } } } message: { Text("\(repository.fullName)/\(file.path)") }
            .confirmationDialog("Discard file edits?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
        }
    }
    private func save() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { let sha = try await store.client.updateFile(in: repository, file: file, branch: branch, text: text, message: message); onSaved(sha, text); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct ReleaseEditor: View {
    let repository: Repository
    let release: Release
    let onSaved: (Release) -> Void
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes = ""
    @State private var prerelease = false
    @State private var preview = false
    @State private var busy = false
    @State private var error: String?
    @State private var discard = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Release") { Text(release.tagName).font(.subheadline.monospaced()); TextField("Release title", text: $name); Toggle("Pre-release", isOn: $prerelease) }.disabled(busy)
                Section("Release notes") {
                    Toggle("Preview Markdown", isOn: $preview)
                    if preview { MarkdownDocumentView(text: notes) }
                    else { TextEditor(text: $notes).frame(minHeight: 240).accessibilityLabel("Release notes").disabled(busy) }
                }
                if busy { ProgressView("Saving release…") }
                if let error { ErrorNotice(message: error) }
            }.navigationTitle("Edit release").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discard = true }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy) }
            }.interactiveDismissDisabled()
            .onAppear { name = release.name ?? ""; notes = release.body ?? ""; prerelease = release.prerelease }
            .confirmationDialog("Discard release edits?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
        }
    }
    private func save() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { let updated = try await store.client.editRelease(in: repository, release: release, name: name, notes: notes, prerelease: prerelease); onSaved(updated); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
