import SwiftUI

@MainActor
struct RunDetailView: View {
    let entry: RepositoryRun
    @Environment(ForgeStore.self) private var store
    @State private var currentRun: WorkflowRun?
    @State private var jobs: [WorkflowJob] = []
    @State private var artifacts: [Artifact] = []
    @State private var jobPage = 0
    @State private var artifactPage = 0
    @State private var moreJobs = false
    @State private var moreArtifacts = false
    @State private var busy = false
    @State private var runError: String?
    @State private var jobError: String?
    @State private var artifactError: String?
    @State private var action: WorkflowAction = .rerunFailed
    @State private var confirmAction = false
    @State private var actionMessage: String?
    private var run: WorkflowRun { currentRun ?? entry.run }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.repository.fullName).font(.caption).foregroundStyle(.secondary)
                    Text(run.displayTitle).font(.title2.bold()).textSelection(.enabled)
                    StatusBadge(state: run.state)
                    Label(run.headBranch ?? "Unknown branch", systemImage: "arrow.triangle.branch").font(.subheadline)
                    Text("Run #\(String(run.runNumber)) · Attempt \(String(run.runAttempt)) · \(run.headSha.prefix(7))")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                if store.hasToken {
                    if run.status == "completed" {
                        Button("Re-run all jobs") { action = .rerun; confirmAction = true }.disabled(busy)
                        if run.state == .failed { Button("Re-run failed jobs") { action = .rerunFailed; confirmAction = true }.disabled(busy) }
                    } else { Button("Cancel run", role: .destructive) { action = .cancel; confirmAction = true }.disabled(busy) }
                }
                if let actionMessage { Text(actionMessage).font(.subheadline).foregroundStyle(.secondary) }
                ShareLink(item: run.htmlUrl)
                if let runError { ErrorNotice(message: runError) }
            }

            Section {
                if let artifactError { ErrorNotice(message: artifactError) }
                if artifacts.isEmpty && !busy && artifactError == nil {
                    Text("No artifacts have been uploaded for this run.").foregroundStyle(.secondary)
                }
                ForEach(artifacts) { artifact in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(artifact.name, systemImage: "archivebox").font(.headline).textSelection(.enabled)
                        HStack {
                            Text(fileSize(artifact.sizeInBytes))
                            Spacer()
                            if artifact.isExpired() {
                                Text("Expired").foregroundStyle(.red)
                            } else if let date = artifact.expiresAt {
                                Text("Expires \(date.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let specification = try? DownloadSpec.artifact(artifact, in: entry.repository) {
                            DownloadControl(specification: specification)
                        }
                    }.padding(.vertical, 6)
                }
                if moreArtifacts || artifactError != nil {
                    Button(artifactError == nil ? "Load more artifacts" : "Retry artifacts") { Task { await loadArtifacts() } }.disabled(busy)
                }
            } header: { Label("Build artifacts", systemImage: "shippingbox") }
              footer: { Text("Artifacts download as ZIP files. GitHub does not publish their download counts. Downloads require a token with Actions read access.") }

            Section("Jobs & steps") {
                if let jobError { ErrorNotice(message: jobError) }
                ForEach(jobs) { job in
                    DisclosureGroup {
                        ForEach(job.steps ?? []) { step in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: step.state.symbol).foregroundStyle(step.state.color)
                                    .accessibilityLabel(step.state.rawValue)
                                Text(step.name).font(.subheadline).textSelection(.enabled)
                            }.padding(.vertical, 4)
                        }
                        NavigationLink("View and search logs") { JobLogView(repository: entry.repository, job: job) }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(job.name).font(.headline)
                            StatusBadge(state: job.state)
                        }.padding(.vertical, 6)
                    }
                }
                if jobs.isEmpty && !busy && jobError == nil { Text("No jobs yet.").foregroundStyle(.secondary) }
                if moreJobs || jobError != nil {
                    Button(jobError == nil ? "Load more jobs" : "Retry jobs") { Task { await loadJobs() } }.disabled(busy)
                }
            }
            if busy { HStack { Spacer(); ProgressView("Checking run…"); Spacer() } }
        }
        .navigationTitle(run.name ?? "Workflow run").navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await store.client.clearCache(); await reload() }
        .confirmationDialog("\(action.title) for run #\(run.runNumber)?", isPresented: $confirmAction, titleVisibility: .visible) {
            Button(action.title, role: action == .cancel ? .destructive : nil) { Task { await performAction() } }
        } message: { Text("This changes the workflow on GitHub and requires Actions write access.") }
    }

    private func performAction() async {
        guard !busy else { return }; busy = true; runError = nil; actionMessage = nil
        do {
            try await store.client.controlRun(in: entry.repository, runID: run.id, action: action)
            actionMessage = "GitHub accepted the request. Pull to refresh its progress."
        } catch { runError = error.localizedDescription }
        busy = false
        if runError == nil { await reload() }
    }

    private func reload() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        runError = nil
        do { currentRun = try await store.client.get("/repos/\(entry.repository.fullName)/actions/runs/\(entry.run.id)") }
        catch { runError = error.localizedDescription }
        jobs = []
        artifacts = []
        jobPage = 0
        artifactPage = 0
        await loadArtifactsPage()
        await loadJobsPage()
    }

    private func loadArtifacts() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await loadArtifactsPage()
    }

    private func loadArtifactsPage() async {
        artifactError = nil
        do {
            let fetched = try await store.client.artifacts(in: entry.repository, runID: run.id, page: artifactPage + 1)
            artifacts += fetched.filter { item in !artifacts.contains(where: { $0.id == item.id }) }
            artifactPage += 1
            moreArtifacts = fetched.count == 100
        } catch { artifactError = error.localizedDescription }
    }

    private func loadJobs() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await loadJobsPage()
    }

    private func loadJobsPage() async {
        jobError = nil
        do {
            let fetched = try await store.client.jobs(in: entry.repository, run: run, page: jobPage + 1)
            jobs += fetched.filter { item in !jobs.contains(where: { $0.id == item.id }) }
            jobPage += 1
            moreJobs = fetched.count == 100
        } catch { jobError = error.localizedDescription }
    }
}
