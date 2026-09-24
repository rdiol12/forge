package app.forge.github

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.Instant

fun statusColor(status: String): Color = when (status) { "success", "completed" -> Color(0xFF1A7F37); "failure", "timed_out", "action_required" -> Color(0xFFCF222E); "in_progress", "queued", "waiting", "pending" -> Color(0xFF9A6700); else -> Color(0xFF6E7781) }
fun runStatus(run: JSONObject) = run.s("conclusion").ifBlank { run.s("status") }

@Composable fun RunRow(repo: String, run: JSONObject) {
    val state = LocalForge.current
    RowLink(run.s("display_title").ifBlank { run.s("name") }, "$repo · ${run.s("head_branch")} · ${runStatus(run).replace('_', ' ')}\n#${run.optLong("run_number")} · ${run.s("created_at").take(16).replace('T', ' ')}", R.drawable.ic_workflow, statusColor(runStatus(run))) {
        state.open(Page("run", run.s("name"), repo, run.s("id")))
    }
}

@Composable fun Runs(page: Page) {
    val state = LocalForge.current; var filter by remember { mutableStateOf(if (page.kind == "latest") "success" else "") }
    Screen {
        if (page.kind == "latest") Note("Newest successful runs first. Open the first run for its latest retained artifacts.")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf("" to "All", "in_progress" to "Active", "failure" to "Failed", "success" to "Passed").forEach { (value, label) -> FilterChip(filter == value, { filter = value }, { Text(label) }) } }
        Group { Paged(filter, load = { number -> state.api.obj("/repos/${repository(page.repo)}/actions/runs", mapOf("per_page" to "30", "page" to number.toString()) + if (filter.isNotEmpty()) mapOf("status" to filter) else emptyMap()).rows("workflow_runs") }) { RunRow(page.repo, it) } }
    }
}

@Composable fun OwnedActions() { Repositories(Page("actionProjects", "Actions", arg = "owned")) }

@Composable fun RunDetail(page: Page) {
    val state = LocalForge.current; var control by remember { mutableStateOf<String?>(null) }
    val path = "/repos/${repository(page.repo)}/actions/runs/${positiveID(page.id)}"
    Screen { Loaded(page, load = { state.api.obj(path) }) { run ->
        Text(run.s("display_title"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Text(runStatus(run).replace('_', ' '), color = statusColor(runStatus(run)))
        Note("${run.s("head_branch")} · ${run.s("head_sha").take(12)} · attempt ${run.optInt("run_attempt")}")
        if (state.connected) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (run.s("status") != "completed") OutlinedButton(onClick = { control = "cancel" }) { Text("Cancel run") }
            else {
                OutlinedButton(onClick = { control = "rerun" }) { Text("Re-run all") }
                if (runStatus(run) in listOf("failure", "timed_out", "cancelled")) OutlinedButton(onClick = { control = "rerun-failed-jobs" }) { Text("Re-run failed") }
            }
        }
        if (state.connected) DeploymentReviews(page)
        Group("Jobs & Tests") { Paged("${page.id}-${run.optInt("run_attempt")}", load = { number -> state.api.obj("$path/attempts/${run.optInt("run_attempt", 1)}/jobs", mapOf("per_page" to "30", "page" to number.toString())).rows("jobs") }) { job ->
            Column {
                RowLink(job.s("name"), runStatus(job).replace('_', ' '), R.drawable.ic_workflow, statusColor(runStatus(job))) { state.open(Page("log", job.s("name"), page.repo, job.s("id"))) }
                job.rows("steps").forEach { step -> Text("${if (step.s("conclusion") == "success") "✓" else "•"} ${step.s("name")} · ${runStatus(step).replace('_', ' ')}", color = statusColor(runStatus(step)), style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(start = 24.dp, end = 12.dp, bottom = 8.dp)) }
            }
        } }
        Group("Artifacts") {
            Note("GitHub does not expose download counts for Actions artifacts.")
            Paged("artifacts-${page.id}", load = { number -> state.api.obj("$path/artifacts", mapOf("per_page" to "30", "page" to number.toString())).rows("artifacts") }) { artifact ->
                val expired = artifact.optBoolean("expired") || runCatching { Instant.parse(artifact.s("expires_at")).isBefore(Instant.now()) }.getOrDefault(false)
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(artifact.s("name"), fontWeight = FontWeight.Medium); Note("${bytes(artifact.optLong("size_in_bytes"))} · ${if (expired) "Expired" else "Expires ${artifact.s("expires_at").take(10)}"}")
                    if (!expired) DownloadButton(DownloadSpec("/repos/${page.repo}/actions/artifacts/${positiveID(artifact.s("id"))}/zip", artifact.s("name") + ".zip", auth = true, sourceURL = "https://github.com/${page.repo}/actions/runs/${page.id}/artifacts/${artifact.s("id")}"))
                }
            }
        }
        control?.let { action -> EditDialog(if (action == "cancel") "Cancel workflow run?" else "Re-run workflow?", emptyList(), "${page.repo}\n${run.s("name")} #${run.optLong("run_number")}\n${run.s("head_branch")} · ${run.s("head_sha").take(12)}", "Confirm", dismiss = { control = null }) { state.api.change("$path/$action"); state.notice = "GitHub accepted the request. Refresh to see its progress." } }
    } }
}

@Composable private fun DeploymentReviews(page: Page) {
    val state = LocalForge.current
    var selected by remember { mutableStateOf<JSONObject?>(null) }; var approved by remember { mutableStateOf(true) }
    Group("Deployment reviews") {
        Loaded(page to "deployments", load = { (state.api.request("/repos/${repository(page.repo)}/actions/runs/${positiveID(page.id)}/pending_deployments") as org.json.JSONArray).objects() }) { pending ->
            if (pending.isEmpty()) Note("No pending deployment reviews.")
            pending.forEach { item ->
                Text(item.o("environment").s("name"), fontWeight = FontWeight.Bold, modifier = Modifier.padding(12.dp))
                if (item.optBoolean("current_user_can_approve")) Row(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { approved = true; selected = item }) { Text("Approve") }
                    OutlinedButton(onClick = { approved = false; selected = item }) { Text("Reject") }
                } else Note("Waiting for an eligible reviewer or protection rule.")
            }
        }
    }
    selected?.let { item -> EditDialog(if (approved) "Approve deployment" else "Reject deployment", listOf(Field("Review comment", multiline = true)), "${page.repo} · Run ${page.id} · ${item.o("environment").s("name")}", "Submit review", dismiss = { selected = null }) { values ->
        state.api.reviewDeployment(page.repo, page.id, item.o("environment").getLong("id"), approved, values[0])
    } }
}

@Composable fun DownloadButton(spec: DownloadSpec) {
    val state = LocalForge.current
    DownloadLinkMenu(spec, onClick = { state.task { state.downloads.start(state.api, spec); state.notice = "Download started. Open Downloads to view progress." } }) { modifier ->
        Surface(shape = ButtonDefaults.outlinedShape, border = ButtonDefaults.outlinedButtonBorder(enabled = true), color = MaterialTheme.colorScheme.surface, contentColor = MaterialTheme.colorScheme.primary) {
            Box(modifier.minimumInteractiveComponentSize().padding(ButtonDefaults.ContentPadding), contentAlignment = androidx.compose.ui.Alignment.Center) { Text("Download", style = MaterialTheme.typography.labelLarge) }
        }
    }
}

@Composable private fun DownloadLinkMenu(spec: DownloadSpec, onClick: () -> Unit = {}, content: @Composable (Modifier) -> Unit) {
    val state = LocalForge.current; val clipboard = LocalClipboardManager.current
    var menu by remember(spec.path, spec.sourceURL) { mutableStateOf(false) }
    Box {
        content(Modifier.combinedClickable(role = Role.Button, onClick = onClick, onLongClickLabel = "Copy download link", onLongClick = { menu = true }))
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(text = { Text("Copy download link") }, onClick = { clipboard.setText(AnnotatedString(spec.downloadURL)); menu = false; state.notice = "Download link copied." })
        }
    }
}

@Composable fun LogScreen(page: Page) {
    val state = LocalForge.current; val path = "/repos/${repository(page.repo)}/actions/jobs/${positiveID(page.id)}/logs"
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 16.dp)) { DownloadButton(DownloadSpec(path, "${page.title}-${page.id}.log")) }
        Loaded(page, load = { state.api.log(path) }) { CodeReader(it, "job.log") }
    }
}

@Composable fun DownloadScreen() {
    val state = LocalForge.current; val context = LocalContext.current; var saving by remember { mutableStateOf<DownloadEntry?>(null) }
    var deleting by remember { mutableStateOf<DownloadEntry?>(null) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val entry = saving; saving = null
        if (uri != null && entry != null) state.task {
            withContext(Dispatchers.IO) { state.downloads.file(entry).inputStream().use { input -> context.contentResolver.openOutputStream(uri)?.use { input.copyTo(it) } ?: error("Could not open the selected destination.") } }
            state.notice = "File saved."
        }
    }
    LaunchedEffect(Unit) { while (true) { state.downloads.refresh(); delay(2000) } }
    Screen {
        if (state.downloads.entries.isEmpty()) Note("Downloaded release files, artifacts, repository ZIPs, and logs appear here.")
        state.downloads.entries.forEach { entry -> Group { DownloadLinkMenu(entry.spec) { modifier ->
            Column(modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(entry.spec.name, fontWeight = FontWeight.Medium); Text(entry.status, style = MaterialTheme.typography.bodySmall)
                if (entry.active) { entry.progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) } ?: LinearProgressIndicator(Modifier.fillMaxWidth()); TextButton(onClick = { state.downloads.cancel(entry) }) { Text("Cancel") } }
                else if (entry.status == "Saved" && runCatching { state.downloads.file(entry) }.isSuccess) Row {
                    TextButton(onClick = { state.task { state.downloads.file(entry); saving = entry; export.launch(entry.spec.name) } }) { Text("Save as…") }
                    TextButton(onClick = { state.task { state.downloads.share(entry) } }) { Text("Share") }
                } else {
                    if (entry.status == "Saved") Note("The local file was removed. Download it again to save or share it.")
                    TextButton(onClick = { state.task { state.downloads.retry(state.api, entry) } }) { Text("Try again") }
                }
                TextButton(onClick = { deleting = entry }) { Text(if (!entry.active && entry.status != "Saved") "Remove failed download" else "Delete downloaded file", color = MaterialTheme.colorScheme.error) }
            }
        } } }
        Note("Archives and release assets continue through Android's download manager. Direct API files need Forge running. Try again starts a fresh request if a signed download URL expires.")
    }
    deleting?.let { entry -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("Delete this download?") },
        text = { Text("Remove ${entry.spec.name} from Forge. Exported copies and files on GitHub are kept.") },
        confirmButton = { TextButton(onClick = { state.task { state.downloads.remove(entry); deleting = null } }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } }) }
}
