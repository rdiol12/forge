package app.forge.github

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.Base64

fun validOfflineCopy(copy: JSONObject): Boolean = runCatching {
    repository(copy.getString("repository")); require(validBranch(copy.getString("branch")) && validSha(copy.getString("sha")))
    require(copy.getLong("saved") > 0 && copy.getInt("omitted") >= 0)
    val files = copy.getJSONObject("files"); require(files.length() <= 100)
    var total = 0
    files.keys().forEach { path ->
        require(safePath(path)); val text = files.getString(path); val size = text.toByteArray().size
        require(size <= 1_048_576 && '\u0000' !in text); total += size
    }
    require(total <= 10_485_760)
}.isSuccess

suspend fun GitHub.offlineCopy(repo: String, branch: String, sha: String): JSONObject {
    repository(repo); require(validBranch(branch) && validSha(sha))
    val tree = obj("/repos/$repo/git/trees/$sha", mapOf("recursive" to "1"))
    require(!tree.optBoolean("truncated")) { "This repository is too large for an offline snapshot. Download individual files from Code." }
    val entries = tree.rows("tree").filter { it.s("type") != "tree" }.sortedBy { it.s("path") }
    val files = JSONObject(); var total = 0; var fetched = 0
    // ponytail: cap explicit snapshots at 100 text files / 10 MiB; individual downloads cover larger repositories.
    for (entry in entries) {
        currentCoroutineContext().ensureActive()
        val size = entry.optInt("size", -1)
        if (entry.s("type") != "blob" || entry.s("mode") !in listOf("100644", "100755") || size !in 0..1_048_576 || fetched >= 100 || total + size > 10_485_760) continue
        require(validSha(entry.s("sha")) && safePath(entry.s("path"))) { "Invalid repository file metadata." }
        fetched++
        val blob = obj("/repos/$repo/git/blobs/${entry.s("sha")}")
        require(blob.s("encoding") == "base64" && blob.optInt("size", -1) == size)
        val data = Base64.getMimeDecoder().decode(blob.getString("content"))
        require(data.size == size) { "GitHub returned an incomplete file. The previous offline copy is unchanged." }
        if (data.contains(0)) continue
        val text = runCatching { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(data)).toString() }.getOrNull() ?: continue
        files.put(entry.s("path"), text); total += size
    }
    return json("repository" to repo, "branch" to branch, "sha" to sha, "saved" to System.currentTimeMillis(), "files" to files, "omitted" to entries.size - files.length())
}

@Composable fun OfflineLibrary() {
    val state = LocalForge.current
    Screen {
        Note("Saved code and documents work without a connection. Save from Repository > More > Offline copy. Copies are removed when you disconnect or change accounts.")
        val copies = remember(state.account, state.refresh) { runCatching { state.offlineCopies() } }
        copies.exceptionOrNull()?.let { ErrorText(it.message ?: "Could not read offline copies.") }
        Group { copies.getOrDefault(emptyList()).forEach { copy ->
            RowLink(copy.s("repository"), "${copy.s("branch")} · ${copy.o("files").length()} files", R.drawable.ic_repo) { state.open(Page("offline", "Offline copy", copy.s("repository"))) }
        } }
        if (copies.getOrDefault(emptyList()).isEmpty()) Note("No offline repositories saved.")
    }
}

@Composable fun OfflineRepository(page: Page) {
    val state = LocalForge.current; val scope = rememberCoroutineScope()
    var copy by remember(page.repo, state.account) { mutableStateOf<JSONObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }; var busy by remember { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }; var deleting by remember { mutableStateOf(false) }
    LaunchedEffect(page.repo, state.account) { try { copy = state.offlineCopies().firstOrNull { it.s("repository").equals(page.repo, true) } } catch (e: Exception) { error = e.message } }
    Screen {
        Note("Save up to 100 UTF-8 code and document files, 1 MiB each and 10 MiB total. Images, history, submodules, and other omitted files need a connection. One branch per repository is stored on this device.")
        copy?.let { Note("${it.s("branch")} · ${it.s("sha").take(8)}\nSaved ${java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it.getLong("saved")))}\n${it.o("files").length()} files · ${it.optInt("omitted")} omitted") }
        if (page.branch.isNotBlank() || copy != null) TextButton(enabled = !busy && state.connected, onClick = { scope.launch {
            busy = true; error = null
            try {
                val account = state.account; val api = state.api; val branch = page.branch.ifBlank { copy?.s("branch") ?: "" }; require(validBranch(branch))
                api.cache?.clear(); val ref = api.obj("/repos/${repository(page.repo)}/git/ref/heads/$branch")
                val next = api.offlineCopy(page.repo, branch, ref.o("object").s("sha"))
                state.saveOffline(next, account); copy = next
            } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { error = e.message } finally { busy = false }
        } }) { Text(if (copy == null) "Save branch offline" else "Update offline copy") }
        if (copy != null) TextButton(enabled = !busy, onClick = { deleting = true }) { Text("Delete offline copy", color = MaterialTheme.colorScheme.error) }
        if (busy) Loading(); error?.let { ErrorText(it) }
        OutlinedTextField(search, { search = it }, label = { Text("Find saved files") }, modifier = Modifier.fillMaxWidth())
        Group("Saved files") { copy?.o("files")?.keys()?.asSequence()?.toList()?.sorted()?.filter { it.contains(search, true) }?.forEach { path ->
            RowLink(path, icon = R.drawable.ic_repo) { state.open(Page("offlineFile", path.substringAfterLast('/'), page.repo, arg = path)) }
        } }
    }
    if (deleting) AlertDialog(onDismissRequest = { deleting = false }, title = { Text("Delete offline copy?") }, text = { Text("Remove the saved files for ${page.repo} from this device.") }, confirmButton = { TextButton(onClick = {
        try { state.deleteOffline(page.repo); copy = null; deleting = false } catch (e: Exception) { error = e.message; deleting = false }
    }) { Text("Delete local copy") } }, dismissButton = { TextButton(onClick = { deleting = false }) { Text("Cancel") } })
}

@Composable fun OfflineFile(page: Page) {
    val state = LocalForge.current; val clipboard = LocalClipboardManager.current
    val saved = remember(page, state.account) { runCatching { state.offlineCopies().first { it.s("repository").equals(page.repo, true) }.o("files").getString(page.arg) } }
    Column(Modifier.fillMaxSize()) {
        TextButton(onClick = { clipboard.setText(AnnotatedString(page.arg)); state.notice = "Path copied" }) { Text("Copy path") }
        saved.exceptionOrNull()?.let { ErrorText(it.message ?: "This file is no longer saved.") }
        saved.getOrNull()?.let { text ->
            if (page.arg.substringAfterLast('.').lowercase() in listOf("md", "markdown")) Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) { Markdown(text) }
            else CodeReader(text, page.arg)
        }
    }
}
