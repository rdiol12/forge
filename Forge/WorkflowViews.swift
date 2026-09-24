import SwiftUI
import UIKit

@MainActor
struct OwnedActionsView: View {
    var body: some View { AccountRepositoriesView(collection: .owned, showsActions: true) }
}

@MainActor
struct LatestBuildView: View {
    let repository: Repository
    @Environment(ForgeStore.self) private var store
    @State private var runs: [WorkflowRun] = []
    @State private var selected: Int64 = 0
    @State private var artifacts: [Artifact] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var artifactError: String?
    @State private var artifactBusy = false
    var body: some View {
        List {
            Section {
                if !runs.isEmpty {
                    Picker("Successful run", selection: $selected) {
                        ForEach(runs) { run in Text("\(run.name ?? "Build") #\(run.runNumber) · \(run.headBranch ?? "")").tag(run.id) }
                    }
                    if let run = runs.first(where: { $0.id == selected }) {
                        Text(run.displayTitle).font(.headline)
                        Text(run.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        NavigationLink("View run and tests") { RunDetailView(entry: RepositoryRun(repository: repository, run: run)) }
                    }
                }
                if busy { ProgressView("Finding successful builds…") }
                if let error { ErrorNotice(message: error); Button("Retry") { Task { await load(reset: page == 0) } } }
                if more && !busy { Button("Load older successful runs") { Task { await load(reset: false) } } }
                if runs.isEmpty && !busy && error == nil { Text("No successful workflow runs yet.") }
            } header: { Text(repository.fullName).textCase(nil) }
              footer: { Text("Starts with the most recent successful run. Choose another workflow or an older run if it produced the build you need.") }
            Section("Build downloads") {
                ForEach(artifacts) { artifact in
                    if let spec = try? DownloadSpec.artifact(artifact, in: repository, runID: selected) {
                        VStack(alignment: .leading, spacing: 10) { Text(artifact.name).font(.headline); Text(fileSize(artifact.sizeInBytes)).font(.caption).foregroundStyle(.secondary); DownloadControl(specification: spec) }
                    }
                }
                if artifactBusy { ProgressView("Loading artifacts…") }
                if let artifactError { ErrorNotice(message: artifactError); Button("Retry artifacts") { Task { await loadArtifacts() } } }
                if selected != 0 && artifacts.isEmpty && !artifactBusy && artifactError == nil { Text("This run has no retained artifacts. Choose an earlier successful run or check Releases.").foregroundStyle(.secondary) }
            }
            NavigationLink("Releases & IPA files") { ReleasesView(repository: repository) }
        }.navigationTitle("Latest build").navigationBarTitleDisplayMode(.inline)
        .task(id: store.account) { await load(reset: true) }
        .task(id: selected) { await loadArtifacts() }
        .refreshable { await store.client.clearCache(); await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        if reset { runs = []; page = 0; more = false; artifacts = []; selected = 0 }
        do {
            let fetched = try await store.client.runs(in: repository, page: page + 1, status: "success")
            guard !Task.isCancelled else { return }
            runs += fetched.filter { next in !runs.contains { $0.id == next.id } }; page += 1; more = fetched.count == 30
            if selected == 0 { selected = runs.first?.id ?? 0 }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadArtifacts() async {
        let id = selected; artifacts = []; artifactError = nil; artifactBusy = false
        guard id > 0 else { return }; artifactBusy = true
        defer { if selected == id { artifactBusy = false } }
        do {
            var page = 1
            while true {
                let result = try await store.client.artifacts(in: repository, runID: id, page: page)
                guard !Task.isCancelled, id == selected else { return }
                artifacts += result.filter { !$0.isExpired() }; page += 1
                if result.count < 100 { break }
            }
        } catch { if !Task.isCancelled, id == selected { artifactError = error.localizedDescription } }
    }
}

@MainActor
struct JobLogView: View {
    let repository: Repository
    let job: WorkflowJob
    @Environment(ForgeStore.self) private var store
    @State private var log: String?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            if let log { CodeTextView(text: log, filename: "job.log") }
            else if busy { Spacer(); ProgressView("Loading job logs…"); Spacer() }
            else if let error { ContentUnavailableView("Logs unavailable", systemImage: "doc.text", description: Text(error)) }
            HStack {
                DownloadControl(specification: .jobLog(in: repository, job: job))
                Spacer()
                Button("Refresh") { Task { await load() } }.disabled(busy)
            }.padding().background(.bar)
            if job.status != "completed" { Text("GitHub may make logs available only after the job finishes.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
        }.navigationTitle(job.name).navigationBarTitleDisplayMode(.inline).task { await load() }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { let text = try await store.client.jobLog(in: repository, jobID: job.id); guard !Task.isCancelled else { return }; log = text }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
