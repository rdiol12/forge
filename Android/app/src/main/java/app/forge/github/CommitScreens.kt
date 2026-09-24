package app.forge.github

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

@Composable fun CommitsScreen(page: Page) {
    val state = LocalForge.current
    Screen { Loaded(page.repo to page.branch, load = { state.api.obj("/repos/${repository(page.repo)}/git/ref/heads/${page.branch}").o("object").s("sha") }) { head ->
        Note("${page.repo} · ${page.branch}")
        Group { Paged(head, load = { state.api.list("/repos/${page.repo}/commits", it, mapOf("sha" to head)) }) { item ->
            RowLink(item.o("commit").s("message").lineSequence().first(), "${item.s("sha").take(7)} · ${item.o("commit").o("author").s("name")}") {
                state.open(Page("commit", item.s("sha").take(7), page.repo, id = item.s("sha"), sha = head, branch = page.branch))
            }
        } }
    } }
}

@Composable fun CommitScreen(page: Page) {
    val state = LocalForge.current; var action by rememberSaveable { mutableStateOf<String?>(null) }
    var conflict by remember { mutableStateOf<HistoryConflict?>(null) }
    val resolutions = remember(page) { mutableMapOf<String, HistoryResolution>() }
    Screen { Loaded(page, load = { require(validSha(page.id)); state.api.obj("/repos/${repository(page.repo)}/commits/${page.id}", mapOf("per_page" to "30")) to state.api.obj("/repos/${page.repo}") }) { (commit, repo) ->
        Group { Note(commit.o("commit").s("message")); Note("${page.id}\n${page.branch}") }
        Group("Changed files") {
            Paged(page.id, load = { state.api.obj("/repos/${page.repo}/commits/${page.id}", mapOf("per_page" to "30", "page" to it.toString())).rows("files") }) { file ->
                var expanded by remember(file.s("filename")) { mutableStateOf(false) }
                RowLink(file.s("filename"), "${file.s("status")} · +${file.optInt("additions")} −${file.optInt("deletions")}") { expanded = !expanded }
                if (expanded) CommitDiff(file.s("patch").ifBlank { "GitHub has no text diff for this file." })
            }
        }
        if (repo.o("permissions").optBoolean("push")) Group("Commit actions") {
            val enabled = commit.rows("parents").size == 1
            TextButton(enabled = enabled, onClick = { resolutions.clear(); action = "Undo changes" }) { Text("Undo changes") }
            TextButton(enabled = enabled, onClick = { resolutions.clear(); action = "Remove from history" }) { Text("Remove from history", color = MaterialTheme.colorScheme.error) }
            Note("Undo adds a new commit. Removing rewrites later commits. Separate text edits merge automatically. Overlapping files open a conflict editor. Root commits and merge rewrites need desktop Git. Repository rules still apply.")
        }
        action?.let { choice ->
            val remove = choice == "Remove from history"
            val account = state.account
            EditDialog(choice, emptyList(), if (remove) "Remove ${page.id.take(7)} from ${page.branch} and replay up to 200 later commits. Later commit IDs change and their original signatures are lost. Collaborators must reconcile local branches. Copies in other branches, tags, forks, or GitHub storage remain. Forge stops if the branch changed or files conflict."
                else "Create a new commit on ${page.branch} that undoes ${page.id.take(7)}. Existing history stays available. Forge stops if the branch changed or files conflict.", "Confirm", required = if (remove) page.branch else null, dismiss = { action = null }) {
                try { state.api.changeHistory(page.repo, page.branch, page.sha, page.id, remove, resolutions) { state.saveRecovery(it, account) }; state.back() }
                catch (e: HistoryConflict) { conflict = e; throw e }
            }
        }
    } }
    conflict?.let { item -> HistoryConflictDialog(item, dismiss = { conflict = null }) { resolutions[item.key] = it; conflict = null; state.notice = "Resolution saved. Confirm again to continue." } }
}

@Composable fun DeletedCommits(repo: String) {
    val state = LocalForge.current
    val groups = state.recoveries.filter { repo.isBlank() || it.s("repository") == repo }.groupBy { it.s("repository") }.toSortedMap()
    Screen {
        Note("Local records from this account's removal attempts. Forge saves commit IDs, not a permanent backup. Recovery works only while GitHub retains the objects. Removing the app removes these records.")
        groups.forEach { (name, entries) -> Group(name) {
            entries.sortedByDescending { it.s("created") }.forEach { item -> RowLink(item.s("message").lineSequence().first(), "${item.s("selected").take(7)} · ${item.s("branch")} · ${item.s("created").take(10)}") {
                state.open(Page("restoreCommit", "Restore commit", name, id = item.s("id")))
            } }
        } }
        if (groups.isEmpty()) Note("No saved commits. Commits removed through Forge on this device appear here.")
    }
}

@Composable fun RestoreCommit(page: Page) {
    val state = LocalForge.current
    val item = state.recoveries.firstOrNull { it.s("id") == page.id } ?: return
    var action by rememberSaveable { mutableStateOf<String?>(null) }
    var conflict by remember { mutableStateOf<HistoryConflict?>(null) }
    val resolutions = remember(page) { mutableMapOf<String, HistoryResolution>() }
    Screen {
        Group { Note(item.s("message")); Note("${page.repo} · ${item.s("branch")}\n${item.s("selected")}") }
        Loaded(page, load = {
            state.api.cache?.clear()
            try {
                state.api.obj("/repos/${repository(page.repo)}/commits/${item.s("selected")}")
                state.api.obj("/repos/${page.repo}/git/ref/heads/${item.s("branch")}").o("object").s("sha")
            } catch (e: Exception) { error("Recovery unavailable: ${e.message}. The commit or branch may be gone, or your access may have changed.") }
        }) { head ->
            Note(if (head == item.s("oldHead")) "The branch already has its saved history; removal did not finish or it was restored." else "GitHub still has this commit.")
            Button(enabled = head == item.s("newHead"), onClick = { action = "Restore saved history" }) { Text("Restore saved history") }
            OutlinedButton(enabled = head != item.s("oldHead"), onClick = { action = "Reapply commit" }) { Text("Reapply commit") }
            Note("Restore returns the branch to its saved history only if it has not moved since removal. Reapply creates a new commit. Separate text edits merge automatically; overlapping files open a conflict editor.")
            action?.let { choice -> EditDialog(choice, emptyList(), "This changes ${item.s("branch")} in ${page.repo}. GitHub permissions and branch rules apply.", "Confirm", dismiss = { action = null }) {
                try { state.api.restoreHistory(item, head, choice == "Reapply commit", resolutions) }
                catch (e: HistoryConflict) { conflict = e; throw e }
                state.notice = if (choice == "Reapply commit") "Commit reapplied." else "Saved branch history restored."
            } }
        }
    }
    conflict?.let { file -> HistoryConflictDialog(file, dismiss = { conflict = null }) { resolutions[file.key] = it; conflict = null; state.notice = "Resolution saved. Confirm again to continue." } }
}

@Composable private fun CommitDiff(text: String) {
    androidx.compose.foundation.text.selection.SelectionContainer { Text(text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, modifier = Modifier.horizontalScroll(rememberScrollState()).padding(12.dp)) }
}


@Composable fun HistoryConflictDialog(conflict: HistoryConflict, dismiss: () -> Unit, resolved: (HistoryResolution) -> Unit) {
    var version by remember(conflict.key) { mutableIntStateOf(0) }
    var choice by remember(conflict.key) { mutableStateOf("") }
    var text by remember(conflict.key) { mutableStateOf(conflict.currentText ?: "") }
    val entry = listOf(conflict.current, conflict.requested, conflict.before)[version]
    val source = listOf(conflict.currentText, conflict.requestedText, conflict.baseText)[version]
    AlertDialog(onDismissRequest = dismiss, title = { Text("Resolve file conflict") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(conflict.path, style = MaterialTheme.typography.titleMedium)
            Text("No branch was changed. Current is the result built so far; Requested is the complete file from the change being applied. Choosing a whole version can retain changes from the removed commit or discard other edits. Review before continuing.")
            Row { listOf("Current", "Requested", "Base").forEachIndexed { index, title -> TextButton(onClick = { version = index }) { Text(if (version == index) "$title \u2713" else title) } } }
            if (source != null) Box(Modifier.height(250.dp)) { CodeReader(source, conflict.path) }
            else Text(entry?.let { "Preview unavailable for this type or size. Revision: ${it.sha}" } ?: "This version does not contain the file.")
            val choices = listOf("current" to if (conflict.current == null) "Keep file deleted" else "Keep current file", "requested" to if (conflict.requested == null) "Delete file as requested" else "Use requested file") + if (conflict.canEdit) listOf("edit" to "Edit final file") else emptyList()
            choices.forEach { (value, label) -> OutlinedButton(onClick = { choice = value }, modifier = Modifier.fillMaxWidth()) { Text(if (choice == value) "$label \u2713" else label) } }
            if (choice == "edit") OutlinedTextField(text, { text = it }, label = { Text("Final file contents") }, minLines = 5, maxLines = 10, modifier = Modifier.fillMaxWidth(), textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace))
            Text("All conflicts must be resolved before you confirm again to update the branch.", style = MaterialTheme.typography.bodySmall)
        }
    }, confirmButton = { TextButton(enabled = choice.isNotEmpty() && (choice != "edit" || (text.toByteArray().size <= 1_048_576 && '\u0000' !in text)), onClick = { resolved(HistoryResolution(choice, text)) }) { Text("Use resolution") } }, dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } })
}
