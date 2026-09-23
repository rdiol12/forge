package app.forge.github

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@Composable fun RepositoryScreen(repo: String) {
    val state = LocalForge.current; val context = LocalContext.current; var branchDialog by remember { mutableStateOf(false) }
    Screen { Loaded(repo, load = { state.api.obj("/repos/${repository(repo)}") }) { info ->
        Group {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(repo, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Text(info.s("description")); Text("${info.s("visibility")} · ${info.optInt("stargazers_count")} stars · ${info.optInt("forks_count")} forks", style = MaterialTheme.typography.bodySmall)
                OutlinedButton(onClick = { state.favorite(repo) }) { Text(if (repo in state.favorites) "Remove favorite" else "Add favorite") }
            }
            RowLink("README", icon = R.drawable.ic_repo) { state.open(Page("readme", "README", repo)) }
            RowLink("Code", "Browse files and switch branches", R.drawable.ic_repo) { state.open(Page("files", "Code", repo)) }
            RowLink("Issues", "${info.optInt("open_issues_count")} open issues and pull requests", R.drawable.ic_issue_opened, Color(0xFF1A7F37)) { state.open(Page("conversations", "Issues", repo, arg = "issue")) }
            RowLink("Pull Requests", icon = R.drawable.ic_git_pull_request) { state.open(Page("conversations", "Pull Requests", repo, arg = "pull")) }
            if (info.optBoolean("has_discussions")) RowLink("Discussions", icon = R.drawable.ic_comment_discussion) { state.open(Page("conversations", "Discussions", repo, arg = "discussion")) }
        }
        Group("Builds & Releases") {
            RowLink("Actions", icon = R.drawable.ic_workflow) { state.open(Page("actions", "Actions", repo)) }
            RowLink("Latest successful build", icon = R.drawable.ic_download) { state.open(Page("latest", "Successful builds", repo)) }
            RowLink("Releases", icon = R.drawable.ic_tag) { state.open(Page("releases", "Releases", repo)) }
        }
        Group {
            if (state.connected) RowLink("Create branch", "Choose a source branch", R.drawable.ic_repo) { branchDialog = true }
            RowLink("Repository settings", "Visibility and permissions", R.drawable.ic_repo) { state.open(Page("repoSettings", "Repository settings", repo)) }
            RowLink("Owner: ${info.o("owner").s("login")}", icon = R.drawable.ic_person) { state.open(Page("profile", info.o("owner").s("login"), id = info.o("owner").s("login"))) }
        }
        if (branchDialog) EditDialog("Create branch", listOf(Field("New branch"), Field("Source branch", info.s("default_branch"))), "Create a new branch in $repo. Existing branches are never overwritten.", "Create", dismiss = { branchDialog = false }) { values ->
            require(validBranch(values[0]) && validBranch(values[1])) { "Enter valid branch names without spaces or refs/ prefixes." }
            val origin = state.api.obj("/repos/$repo/git/ref/heads/${values[1]}")
            require(origin.s("ref") == "refs/heads/${values[1]}" && validSha(origin.o("object").s("sha"))) { "Source branch could not be verified." }
            state.api.change("/repos/$repo/git/refs", body = json("ref" to "refs/heads/${values[0]}", "sha" to origin.o("object").s("sha")))
        }
    } }
}

@Composable fun RepositorySettings(repo: String) {
    val state = LocalForge.current; var confirm by remember { mutableStateOf(false) }
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
            state.favorites.forEach { name -> Group(name) { Loaded(name, load = { state.api.list("/repos/$name/releases") }) { releases -> releases.forEach { ReleaseRow(name, it) } } } }
        } else Group { Paged(repo, load = { state.api.list("/repos/${repository(repo)}/releases", it) }) { ReleaseRow(repo, it) } }
    }
}

@Composable fun ReleaseRow(repo: String, release: JSONObject) {
    val state = LocalForge.current
    RowLink(release.s("name").ifBlank { release.s("tag_name") }, listOf(release.s("tag_name"), release.s("published_at").take(10), if (release.optBoolean("prerelease")) "Pre-release" else "").filter { it.isNotBlank() }.joinToString(" · "), R.drawable.ic_tag) {
        state.open(Page("release", release.s("name").ifBlank { release.s("tag_name") }, repo, release.s("id")))
    }
}

@Composable fun ReleaseScreen(page: Page) {
    val state = LocalForge.current; var edit by remember { mutableStateOf(false) }; var delete by remember { mutableStateOf(false) }
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
            val latest = state.api.obj(path)
            require(listOf("name", "body", "prerelease").all { latest.opt(it) == release.opt(it) }) { "Release changed. Refresh before saving." }
            require(values[2] in listOf("true", "false")) { "Enter true or false for pre-release." }
            state.api.change(path, "PATCH", releaseEdit(values[0], values[1], values[2].toBoolean()))
        }
        if (delete) EditDialog("Delete release?", emptyList(), "Permanently delete ${release.s("tag_name")} and all its uploaded files from ${page.repo}. The Git tag remains.", "Delete release", required = release.s("tag_name"), dismiss = { delete = false }) { state.api.change(path, "DELETE"); state.back() }
    } }
}
