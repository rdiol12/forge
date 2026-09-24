package app.forge.github

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@Composable fun RepositoryScreen(repo: String, initialBranch: String = "") {
    val state = LocalForge.current; val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }; var more by rememberSaveable { mutableStateOf(false) }
    var branchDialog by rememberSaveable { mutableStateOf(false) }; var pickingBranch by rememberSaveable { mutableStateOf(false) }
    var descriptionEditor by rememberSaveable { mutableStateOf(false) }; var selected by rememberSaveable { mutableStateOf(initialBranch) }
    Screen { Loaded(repo, load = { state.api.obj("/repos/${repository(repo)}") }) { info ->
        Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalAlignment = androidx.compose.ui.Alignment.End, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(repo.substringBefore('/'), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(repo.substringAfter('/'), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            if (info.s("description").isNotBlank()) Text(info.s("description"), textAlign = androidx.compose.ui.text.style.TextAlign.End)
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Loaded(repo to "star", load = { state.api.isStarred(repo) }) { starred ->
                    TextButton(enabled = state.connected, onClick = { state.task {
                        state.api.change("/user/starred/$repo", if (starred) "DELETE" else "PUT")
                        if (!starred && repo !in state.favorites) state.favorite(repo)
                        state.refresh++
                    } }) { Text("${if (starred) "?" else "?"} ${info.optInt("stargazers_count")}") }
                }
                TextButton(onClick = { state.open(Page("community", "Forks", repo, arg = "forks")) }) { Text("? ${info.optInt("forks_count")}") }
            }
        }
        Group {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Box {
                    TextButton(onClick = { menu = true }) { Text("???", modifier = Modifier.semanticsLabel("Repository options")) }
                    DropdownMenu(menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Share") }, onClick = { menu = false; context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, "https://github.com/$repo"), "Share repository")) })
                        DropdownMenuItem(text = { Text("Edit description") }, enabled = info.o("permissions").optBoolean("admin"), onClick = { menu = false; descriptionEditor = true })
                        DropdownMenuItem(text = { Text(if (repo in state.favorites) "Remove from favorites" else "Add to favorites") }, onClick = { state.favorite(repo); menu = false })
                        DropdownMenuItem(text = { Text("Create branch") }, enabled = state.connected, onClick = { menu = false; branchDialog = true })
                        DropdownMenuItem(text = { Text("Repository settings") }, onClick = { menu = false; state.open(Page("repoSettings", "Repository settings", repo)) })
                    }
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { state.open(Page("files", "Code", repo, branch = selected)) }) { Text("Code") }
                TextButton(onClick = { state.open(Page("conversations", "Issues", repo, arg = "issue")) }) { Text("Issues") }
            }
            RowLink("Issues", icon = R.drawable.ic_issue_opened, color = Color(0xFF1A7F37)) { state.open(Page("conversations", "Issues", repo, arg = "issue")) }
            RowLink("Pull Requests", icon = R.drawable.ic_git_pull_request) { state.open(Page("conversations", "Pull Requests", repo, arg = "pull")) }
            RowLink("Actions", icon = R.drawable.ic_workflow) { state.open(Page("actions", "Actions", repo)) }
            RowLink("Releases", icon = R.drawable.ic_tag) { state.open(Page("releases", "Releases", repo)) }
            RowLink(if (more) "Less" else "More", icon = R.drawable.ic_repo) { more = !more }
            if (more) {
                RowLink("Contributors", icon = R.drawable.ic_person) { state.open(Page("community", "Contributors", repo, arg = "contributors")) }
                RowLink("Watchers", "${info.optInt("subscribers_count")} watching", R.drawable.ic_person) { state.open(Page("community", "Watchers", repo, arg = "subscribers")) }
                RowLink("License", info.o("license").s("name"), R.drawable.ic_repo) { state.open(Page("license", "License", repo)) }
                if (info.optBoolean("has_discussions")) RowLink("Discussions", icon = R.drawable.ic_comment_discussion) { state.open(Page("conversations", "Discussions", repo, arg = "discussion")) }
                RowLink("Latest successful build", icon = R.drawable.ic_download) { state.open(Page("latest", "Successful builds", repo)) }
                RowLink("Deleted commits", icon = R.drawable.ic_repo) { state.open(Page("deletedCommits", "Deleted commits", repo)) }
            }
        }
        val name = selected.ifBlank { info.s("default_branch") }
        Loaded(repo to name, load = { require(validBranch(name)); state.api.obj("/repos/$repo/git/ref/heads/$name").o("object").getString("sha") }) { sha ->
            Group {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.End) { TextButton(onClick = { pickingBranch = true }) { Text("? $name ?") } }
                RowLink("Code", icon = R.drawable.ic_repo) { state.open(Page("files", "Code", repo, sha = sha, branch = name)) }
                RowLink("Commits", icon = R.drawable.ic_repo) { state.open(Page("commits", "Commits", repo, sha = sha, branch = name)) }
            }
            ReadmeCard(repo, name, sha, info.o("permissions").optBoolean("push"))
        }
        if (descriptionEditor) EditDialog("Edit description", listOf(Field("Description", info.s("description"), true)), dismiss = { descriptionEditor = false }) { state.api.editDescription(repo, info.s("description"), it[0]) }
        if (branchDialog) EditDialog("Create branch", listOf(Field("New branch"), Field("Source branch", name)), "Create a branch in $repo. Existing branches are never overwritten.", "Create", dismiss = { branchDialog = false }) { values ->
            require(validBranch(values[0]) && validBranch(values[1])) { "Enter valid branch names." }; state.api.cache?.clear()
            val origin = state.api.obj("/repos/$repo/git/ref/heads/${values[1]}")
            require(origin.s("ref") == "refs/heads/${values[1]}" && validSha(origin.o("object").s("sha")))
            state.api.change("/repos/$repo/git/refs", body = json("ref" to "refs/heads/${values[0]}", "sha" to origin.o("object").s("sha")))
        }
        if (pickingBranch) AlertDialog(onDismissRequest = { pickingBranch = false }, title = { Text("Branches") }, text = {
            Column(Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState())) {
                var query by remember { mutableStateOf("") }
                OutlinedTextField(query, { query = it }, label = { Text("Filter loaded branches") })
                Paged(repo, load = { state.api.list("/repos/$repo/branches", it) }) { b -> if (b.s("name").contains(query, true)) TextButton(onClick = {
                    selected = b.s("name"); pickingBranch = false
                    if (state.stack.lastOrNull()?.kind == "repo") state.stack[state.stack.lastIndex] = state.stack.last().copy(branch = selected)
                }) { Text(b.s("name")) } }
            }
        }, confirmButton = { TextButton(onClick = { pickingBranch = false }) { Text("Done") } })
    } }
}

@Composable fun RepositoryCommunity(page: Page) {
    val state = LocalForge.current
    Screen { Group { Paged(page, load = { require(page.arg in listOf("forks", "contributors", "subscribers")); state.api.list("/repos/${repository(page.repo)}/${page.arg}", it) }) { item ->
        if (page.arg == "forks") RepoRow(item) else PersonRow(item)
    } } }
}

@Composable fun RepositoryLicense(repo: String) {
    val state = LocalForge.current
    Loaded(repo, load = { state.api.obj("/repos/${repository(repo)}/license") }) { file -> FileScreen(Page("file", file.s("name"), repo, arg = file.s("path"), sha = file.s("sha"))) }
}

@Composable fun RepositorySettings(repo: String) {
    val state = LocalForge.current; var confirm by rememberSaveable { mutableStateOf(false) }
    Screen { Loaded(repo, load = { state.api.obj("/repos/${repository(repo)}") }) { info ->
        Group("Visibility") {
            Note("$repo is ${info.s("visibility")}.")
            if (info.o("permissions").optBoolean("admin") && info.s("visibility") in listOf("public", "private")) TextButton(onClick = { confirm = true }, modifier = Modifier.padding(12.dp)) { Text(if (info.optBoolean("private")) "Make public" else "Make private") }
            else Note("Only repository administrators can change visibility.")
        }
        Note("Default branch: ${info.s("default_branch")}\nRepository rules and token permissions are enforced by GitHub.")
        if (confirm) {
            val makePrivate = !info.optBoolean("private")
            EditDialog(if (makePrivate) "Make repository private?" else "Make repository public?", emptyList(),
                if (makePrivate) "Restrict access to $repo. Existing public forks may remain public; visibility changes affect repository features." else "Anyone will be able to see $repo, including its files and commit history. Check for sensitive information before continuing.",
                if (makePrivate) "Make private" else "Make public", required = repo, dismiss = { confirm = false }) { state.api.setVisibility(repo, info.s("visibility"), makePrivate) }
        }
    } }
}

@Composable fun Releases(repo: String) {
    val state = LocalForge.current
    Screen {
        if (repo.isBlank()) {
            if (state.favorites.isEmpty()) Note("Add a repository to Favorites to follow its releases.")
            Group("Newest releases first") { Loaded(state.favorites.toList(), load = {
                state.favorites.toList().flatMap { name -> state.api.list("/repos/${repository(name)}/releases").map { name to it } }.sortedByDescending { it.second.s("published_at") }
            }) { rows -> rows.forEach { (name, release) -> Note(name); ReleaseRow(name, release) } } }
        } else Group("Newest releases first") { Paged(repo, order = compareByDescending { it.s("published_at") }, load = { state.api.list("/repos/${repository(repo)}/releases", it) }) { ReleaseRow(repo, it) } }
    }
}

@Composable fun ReleaseRow(repo: String, release: JSONObject) {
    val state = LocalForge.current
    RowLink(release.s("name").ifBlank { release.s("tag_name") }, listOf(release.s("tag_name"), release.s("published_at").take(10), if (release.optBoolean("prerelease")) "Pre-release" else "").filter { it.isNotBlank() }.joinToString(" · "), R.drawable.ic_tag) {
        state.open(Page("release", release.s("name").ifBlank { release.s("tag_name") }, repo, release.s("id")))
    }
}

@Composable fun ReleaseScreen(page: Page) {
    val state = LocalForge.current; var edit by rememberSaveable { mutableStateOf(false) }; var delete by rememberSaveable { mutableStateOf(false) }
    val path = "/repos/${repository(page.repo)}/releases/${positiveID(page.id)}"
    Screen { Loaded(page, load = { state.api.obj(path) to state.api.obj("/repos/${page.repo}") }) { (release, repo) ->
        Text(release.s("name").ifBlank { release.s("tag_name") }, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text("${release.s("tag_name")} · ${release.s("published_at").take(10)}" + if (release.optBoolean("prerelease")) " · Pre-release" else "", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Markdown(release.s("body"))
        Group("Files") {
            Paged(page, load = { state.api.list("$path/assets", it) }) { asset ->
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(asset.s("name"), fontWeight = FontWeight.Medium)
                    Note("${bytes(asset.optLong("size"))} · ${asset.optLong("download_count")} downloads")
                    DownloadButton(DownloadSpec("/repos/${page.repo}/releases/assets/${positiveID(asset.s("id"))}", asset.s("name"), "application/octet-stream"))
                }
            }
        }
        if (repo.o("permissions").optBoolean("push") || repo.o("permissions").optBoolean("admin")) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { edit = true }) { Text("Edit release") }; TextButton(onClick = { delete = true }) { Text("Delete release", color = MaterialTheme.colorScheme.error) }
        }
        if (edit) EditDialog("Edit release", listOf(Field("Name", release.s("name")), Field("Release notes", release.s("body"), true), Field("Pre-release (true/false)", release.optBoolean("prerelease").toString())), "Changes only the name, notes, and pre-release status. The tag and draft status stay unchanged.", dismiss = { edit = false }) { values ->
            state.api.cache?.clear()
            val latest = state.api.obj(path)
            require(listOf("name", "body", "prerelease").all { latest.opt(it) == release.opt(it) }) { "Release changed. Refresh before saving." }
            require(values[2] in listOf("true", "false")) { "Enter true or false for pre-release." }
            state.api.change(path, "PATCH", releaseEdit(values[0], values[1], values[2].toBoolean()))
        }
        if (delete) EditDialog("Delete release?", emptyList(), "Permanently delete ${release.s("tag_name")} and all its uploaded files from ${page.repo}. The Git tag remains.", "Delete release", required = release.s("tag_name"), dismiss = { delete = false }) { state.api.change(path, "DELETE"); state.back() }
    } }
}
