import SwiftUI

@MainActor
struct AddRepositoryView: View {
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("owner/repository", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit { add() }
                } header: { Text("Repository") }
                  footer: { Text("For example cli/cli. Connect a token in Settings for private repositories and Actions artifact downloads.") }
                if let error { ErrorNotice(message: error) }
                Button(action: add) {
                    HStack { Text("Add favorite"); Spacer(); if busy { ProgressView() } }
                }.disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle("Add favorite").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await store.addRepository(input); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
struct SettingsView: View {
    @Environment(ForgeStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(store.hasToken ? store.account : "Browsing public repositories", systemImage: store.hasToken ? "checkmark.shield" : "globe")
                    SecureField(store.hasToken ? "Replace personal access token" : "Personal access token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        busy = true
                        error = nil
                        Task {
                            defer { busy = false }
                            do { try await store.connect(token); token = "" }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack { Text("Connect GitHub"); Spacer(); if busy { ProgressView() } }
                    }.disabled(token.isEmpty || busy)
                    if store.hasToken {
                        Button("Disconnect", role: .destructive) {
                            do { try store.disconnect(); downloads.cancelAll() }
                            catch { self.error = error.localizedDescription }
                        }.disabled(busy)
                    }
                    if let error { ErrorNotice(message: error) }
                } header: { Text("GitHub account") }
                  footer: { Text("Your token stays in this iPhone's Keychain and is sent only to GitHub's API. Disconnecting stops active downloads; files you've saved remain in Downloads.") }

                Section("Token access") {
                    LabeledContent("Actions", value: "Read-only")
                    LabeledContent("Contents", value: "Read-only")
                    Text("Create a fine-grained token for your favorite repositories. Actions read access enables artifact downloads; Contents read access enables private release downloads.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Inbox notifications require a classic token with notifications scope (repo scope for private repositories). GitHub does not support fine-grained tokens for this endpoint.").font(.footnote).foregroundStyle(.secondary)
                    Link("Create a classic token for Inbox", destination: URL(string: "https://github.com/settings/tokens/new")!)
                    Link("Create a token on GitHub", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                }

                Section("Favorite repositories") {
                    if store.repositories.isEmpty { Text("No repositories yet").foregroundStyle(.secondary) }
                    ForEach(store.repositories) { repository in
                        HStack {
                            Text(repository.fullName).font(.subheadline.monospaced())
                            Spacer()
                            Button(role: .destructive) { store.removeRepository(repository) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove favorite \(repository.fullName)")
                        }
                    }
                }

                Section("About Forge") {
                    NavigationLink("Open-source licenses") {
                        ScrollView {
                            Text((Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "GitHub Octicons ? MIT License")
                                .font(.footnote).textSelection(.enabled).padding()
                        }.navigationTitle("Licenses").navigationBarTitleDisplayMode(.inline)
                    }
                    Text("An independent GitHub companion for Actions, releases, and the files they produce.")
                    Text("Release asset counts come directly from GitHub. GitHub does not publish download counts for Actions artifacts.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Downloads run while Forge is open. No background monitoring or push alerts in this version.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
        }
    }
}
