package app.forge.github

import android.graphics.BitmapFactory
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI

@Composable fun Home() {
    val state = LocalForge.current; val context = LocalContext.current
    Screen {
        if (!state.connected) Group { RowLink("Connect GitHub", "Access your private repositories and workflows", R.drawable.ic_person) { state.open(Page("settings", "Settings")) } }
        Group("My Work") {
            RowLink("Offline repositories", icon = R.drawable.ic_download) { state.open(Page("offlineList", "Offline repositories")) }
            RowLink("Issues", icon = R.drawable.ic_issue_opened, color = Color(0xFF1A7F37)) { state.open(Page("conversations", "Issues", arg = "issue")) }
            RowLink("Pull Requests", icon = R.drawable.ic_git_pull_request, color = Color(0xFF0969DA)) { state.open(Page("conversations", "Pull Requests", arg = "pull")) }
            RowLink("Discussions", icon = R.drawable.ic_comment_discussion, color = Color(0xFF8250DF)) { state.open(Page("conversations", "Discussions", arg = "discussion")) }
            RowLink("Repositories", icon = R.drawable.ic_repo, color = Color(0xFF57606A)) { state.open(Page("repos", "Your repositories", arg = "owned")) }
            RowLink("Organizations", icon = R.drawable.ic_organization, color = Color(0xFFBC4C00)) { state.open(Page("orgs", "Organizations")) }
            RowLink("Starred", icon = R.drawable.ic_star, color = Color(0xFF9A6700)) { state.open(Page("repos", "Starred repositories", arg = "starred")) }
        }
        Group("Favorites") {
            state.favorites.forEach { repo -> RowLink(repo) { state.open(Page("repo", repo.substringAfter('/'), repo)) } }
            RowLink("Add a repository", "Find a public or private repository", R.drawable.ic_telescope) { state.chooseTab(2) }
        }
        Group("Builds & Downloads") {
            RowLink("Actions", "All your repositories", R.drawable.ic_workflow) { state.open(Page("ownedActions", "Your Actions")) }
            RowLink("Releases", "Releases from your favorites", R.drawable.ic_tag) { state.open(Page("releases", "Releases")) }
            RowLink("Downloads", "Saved files and transfer progress", R.drawable.ic_download) { state.open(Page("downloads", "Downloads")) }
            RowLink("Deleted commits", "Recovery records by repository", R.drawable.ic_repo) { state.open(Page("deletedCommits", "Deleted commits")) }
        }
        if (state.showCopilot) Group { RowLink("Copilot", "Open GitHub Copilot", R.drawable.ic_copilot) { state.link(context, "https://github.com/copilot") } }
    }
}

@Composable fun Settings() {
    val state = LocalForge.current; val context = LocalContext.current; val scope = rememberCoroutineScope()
    var token by remember { mutableStateOf("") }; var busy by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }
    var disconnect by rememberSaveable { mutableStateOf(false) }
    Screen {
        Group("GitHub account") {
            if (state.connected) {
                RowLink(state.account, "Connected securely", R.drawable.ic_person) { state.open(Page("profile", state.account, id = state.account)) }
                TextButton(onClick = { disconnect = true }, modifier = Modifier.padding(horizontal = 12.dp)) { Text("Disconnect") }
            } else {
                Button(onClick = { state.task { state.startLogin(context) } }, enabled = !state.signingIn && !busy, modifier = Modifier.fillMaxWidth().padding(16.dp)) { Text("Sign in with GitHub") }
                Note("Browser sign-in uses GitHub's secure authorization page. If registration is not activated, use a token below.")
            }
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Personal access token", style = MaterialTheme.typography.titleSmall)
                OutlinedTextField(token, { token = it }, label = { Text("GitHub token") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false), enabled = !busy, modifier = Modifier.fillMaxWidth())
                Button(enabled = token.isNotBlank() && !busy, onClick = { busy = true; error = null; state.task { try { state.connect(token); token = "" } catch (e: Exception) { error = e.message } finally { busy = false } } }) { Text(if (busy) "Connecting…" else "Connect token") }
                error?.let { ErrorText(it) }
                TextButton(onClick = { state.link(context, "https://github.com/settings/tokens/new") }) { Text("Create a GitHub token") }
            }
            Note("Classic tokens: repo and notifications; user for profile/follow changes, project for Projects, workflow for workflow-file edits. Fine-grained tokens: Actions and Contents read; add write permissions for Actions controls, issue/PR/Discussion changes, README and releases. Visibility changes require Administration write and repository admin access. Inbox requires OAuth or a classic token.")
        }
        Group("Appearance") { Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) { Text("Show Copilot shortcut", Modifier.weight(1f)); Switch(state.showCopilot, { state.showCopilot = it; state.prefs.edit().putBoolean("copilot", it).apply() }) } }
        Note("Forge · Version ${BuildConfig.VERSION_NAME} (build ${BuildConfig.VERSION_CODE})\nAn independent GitHub companion. Tokens stay encrypted on this device. Website sessions are separate. Downloaded files remain when you disconnect.")
        Group { RowLink("Open source licenses", "Octicons and Android libraries") { state.open(Page("licenses", "Licenses")) } }
    }
    if (disconnect) EditDialog("Disconnect GitHub?", emptyList(), "Active downloads will be cancelled and offline repository copies removed. Downloaded files and favorites remain on this device.", "Disconnect", dismiss = { disconnect = false }) { state.disconnect() }
}

private val avatars = android.util.LruCache<String, android.graphics.Bitmap>(40)
@Composable fun Avatar(login: String, size: Int = 44) {
    var bitmap by remember(login) { mutableStateOf(avatars.get(login)) }
    LaunchedEffect(login) {
        if (bitmap == null && validLogin(login)) bitmap = withContext(Dispatchers.IO) {
            runCatching {
                val c = URI("https://avatars.githubusercontent.com/$login?s=128").toURL().openConnection() as HttpURLConnection
                try { c.connectTimeout = 10_000; c.readTimeout = 10_000; c.instanceFollowRedirects = false
                    if (c.responseCode != 200) null else c.inputStream.use { val bytes = it.readLimited(1_048_576); BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
                } finally { c.disconnect() }
            }.getOrNull()
        }?.also { avatars.put(login, it) }
    }
    Box(Modifier.size(size.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary.copy(alpha = .1f)), contentAlignment = Alignment.Center) {
        bitmap?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize()) } ?: Text(login.take(1).uppercase(), color = MaterialTheme.colorScheme.primary)
    }
}

@Composable fun PersonRow(person: JSONObject) {
    val state = LocalForge.current; val login = person.s("login")
    Row(Modifier.fillMaxWidth().clickable { state.open(Page("profile", login, id = login)) }.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Avatar(login); Column(Modifier.weight(1f)) { Text(person.s("name").ifBlank { login }, fontWeight = FontWeight.Medium); if (person.s("name").isNotBlank()) Text(login, style = MaterialTheme.typography.bodySmall) }; Text("›")
    }
}

@Composable fun Profile(login: String) {
    val state = LocalForge.current; val mine = login.equals(state.account, true)
    var editing by rememberSaveable { mutableStateOf(false) }
    var highlights by remember(login) { mutableStateOf<JSONObject?>(null) }
    var following by remember(login) { mutableStateOf<Boolean?>(null) }
    var followingBusy by remember { mutableStateOf(false) }
    LaunchedEffect(login, state.refresh, state.generation) {
        if (state.connected) {
            highlights = runCatching { state.api.profileHighlights(login) }.getOrNull()
            if (!mine) following = runCatching { state.api.isFollowing(login) }.getOrNull()
        }
    }
    Screen(horizontalPadding = 0) { Loaded(login, load = { require(validLogin(login)); state.api.obj(if (mine) "/user" else "/users/$login") }) { user ->
        val organization = user.s("type") == "Organization"
        Group(modifier = Modifier.padding(horizontal = 16.dp)) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Avatar(login, 76)
                    Column { Text(user.s("name").ifBlank { login }, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold); Text(login, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
                if (user.s("bio").isNotBlank()) Text(user.s("bio"))
                if (user.s("location").isNotBlank()) Text(user.s("location"), style = MaterialTheme.typography.bodySmall)
                if (!organization) Row {
                    TextButton(onClick = { state.open(Page("people", "Followers", id = login, arg = "followers")) }) { Text("${user.optInt("followers")} followers") }
                    TextButton(onClick = { state.open(Page("people", "Following", id = login, arg = "following")) }) { Text("${user.optInt("following")} following") }
                }
                val badges = listOf("isEmployee" to "GitHub Staff", "isDeveloperProgramMember" to "Developer Program", "isGitHubStar" to "GitHub Star", "isCampusExpert" to "Campus Expert").filter { highlights?.optBoolean(it.first) == true }
                if (badges.isNotEmpty()) Text(badges.joinToString(" ? ") { "? ${it.second}" }, color = MaterialTheme.colorScheme.primary)
                if (mine) OutlinedButton(onClick = { editing = true }) { Text("Edit profile") }
                else if (!organization && state.connected && following != null) OutlinedButton(enabled = !followingBusy, onClick = {
                    followingBusy = true; state.task { try { state.api.change("/user/following/${accountPath(login)}", if (following == true) "DELETE" else "PUT"); following = following != true; state.refresh++ } finally { followingBusy = false } }
                }) { Text(if (following == true) "Unfollow" else "Follow") }
            }
        }
        Group(modifier = Modifier.padding(horizontal = 16.dp)) {
            RowLink(if (mine) "Your repositories" else "Repositories", icon = R.drawable.ic_repo) { state.open(Page("repos", "Repositories", id = login, arg = if (mine) "owned" else if (organization) "org" else "user")) }
            if (!organization) {
                RowLink("Starred repositories", icon = R.drawable.ic_star) { state.open(Page("repos", "Starred", id = login, arg = if (mine) "starred" else "stars")) }
                RowLink("Organizations", icon = R.drawable.ic_organization) { state.open(Page("orgs", "Organizations", id = login)) }
            }
            if (mine) RowLink("Your repository Actions", icon = R.drawable.ic_workflow) { state.open(Page("ownedActions", "Your Actions")) }
        }
        if (!organization) {
            Group("Pinned repositories", modifier = Modifier.padding(horizontal = 16.dp)) {
                val pins = highlights?.o("pinnedItems")?.rows("nodes").orEmpty()
                if (pins.isEmpty()) Note(if (state.connected) "No pinned repositories available." else "Connect GitHub to see pinned repositories.")
                pins.forEach { pin -> RowLink(pin.s("nameWithOwner"), pin.s("description") + " ? ? ${pin.optInt("stargazerCount")}") { val repo = repository(pin.s("nameWithOwner")); state.open(Page("repo", repo.substringAfter('/'), repo)) } }
            }
            ProfileReadme(login, mine)
        }
        if (editing) {
            val fields = listOf("name" to "Name", "bio" to "Bio", "blog" to "Website", "company" to "Company", "location" to "Location", "twitter_username" to "Social handle")
            EditDialog("Edit profile", fields.map { Field(it.second, user.s(it.first), it.first == "bio") } + Field("Available for hire", user.optBoolean("hireable").toString(), toggle = true), "Bio: up to 160 characters. Profile write permission is required.", dismiss = { editing = false }) { values ->
                state.api.editProfile(user, fields.mapIndexed { i, f -> f.first to values[i] }.toMap(), values.last().toBoolean())
            }
        }
    } }
}

@Composable private fun ProfileReadme(login: String, mine: Boolean) {
    val state = LocalForge.current; val repo = "$login/$login"
    var branch by remember(login) { mutableStateOf<Pair<String, String>?>(null) }
    var error by remember(login) { mutableStateOf<String?>(null) }
    LaunchedEffect(login, state.refresh) {
        try {
            val name = state.api.obj("/repos/${repository(repo)}").s("default_branch")
            branch = name to state.api.obj("/repos/$repo/git/ref/heads/$name").o("object").s("sha")
        } catch (e: Exception) { error = if (e.message?.contains("404") == true) "No profile README available." else e.message }
    }
    branch?.let { ReadmeCard(repo, it.first, it.second, mine) } ?: error?.let { Note(it) }
}

@Composable fun People(page: Page) {
    val state = LocalForge.current; var search by remember { mutableStateOf("") }
    Screen {
        OutlinedTextField(search, { search = it }, label = { Text("Filter loaded people") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        Group { Paged(page, load = { require(validLogin(page.id) && page.arg in listOf("followers", "following")); state.api.list("/users/${page.id}/${page.arg}", it) }) { person ->
            if (person.s("login").contains(search, true) || person.s("name").contains(search, true)) PersonRow(person)
        } }
    }
}

@Composable fun Repositories(page: Page) {
    val state = LocalForge.current
    var search by rememberSaveable { mutableStateOf("") }
    Screen {
        OutlinedTextField(search, { search = it }, label = { Text("Filter loaded repositories") }, modifier = Modifier.fillMaxWidth())
        if (page.kind == "actionProjects") {
            Note("Choose a project to see its workflow runs, jobs, and artifacts.")
            Group("Favorite projects") { state.favorites.forEach { repo -> RowLink(repo, icon = R.drawable.ic_workflow) { state.open(Page("actions", "Actions", repo)) } } }
        }
        Group(if (page.kind == "actionProjects") "Your projects" else "") { Paged(page, visible = { "${it.s("full_name")} ${it.s("description")}".contains(search, true) }, load = { number ->
        val path = when (page.arg) {
            "owned", "starred" -> { require(state.connected) { "Connect GitHub in Settings to see your repositories." }; if (page.arg == "owned") "/user/repos" else "/user/starred" }
            "org" -> "/orgs/${accountPath(page.id)}/repos"
            "stars" -> "/users/${accountPath(page.id)}/starred"
            else -> "/users/${accountPath(page.id)}/repos"
        }
        state.api.list(path, number, mapOf("sort" to "updated", "direction" to "desc") + if (page.arg == "owned") mapOf("affiliation" to "owner", "visibility" to "all") else emptyMap())
    }) { repo ->
        if (page.kind == "actionProjects") RowLink(repo.s("full_name"), repo.s("description"), R.drawable.ic_workflow) { state.open(Page("actions", "Actions", repo.s("full_name"))) }
        else RepoRow(repo)
    } } }
}

@Composable fun RepoRow(repo: JSONObject) {
    val state = LocalForge.current; val name = repo.s("full_name")
    RowLink(name, listOf(if (repo.optBoolean("private")) "Private" else "Public", repo.s("description")).filter { it.isNotBlank() }.joinToString(" · ")) { state.open(Page("repo", name.substringAfter('/'), repository(name))) }
}

@Composable fun Organizations(login: String) {
    val state = LocalForge.current
    Screen { Group { Paged(login, load = { page ->
        val path = if (login.isBlank() || login == state.account) { require(state.connected) { "Connect GitHub in Settings." }; "/user/orgs" } else "/users/${accountPath(login)}/orgs"
        state.api.list(path, page)
    }) { org -> RowLink(org.s("login"), org.s("description"), R.drawable.ic_organization) { state.open(Page("repos", org.s("login"), id = org.s("login"), arg = "org")) } } } }
}

@Composable fun RepositorySearch() {
    val state = LocalForge.current; var query by rememberSaveable { mutableStateOf("") }; var submitted by rememberSaveable { mutableStateOf("") }
    Screen {
        OutlinedTextField(query, { query = it }, label = { Text("Search repositories or enter owner/name") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { submitted = query.trim() }, enabled = query.isNotBlank()) { Text("Search") }
            if (runCatching { repository(query.trim()) }.isSuccess) OutlinedButton(onClick = { val repo = repository(query.trim()); state.open(Page("repo", repo.substringAfter('/'), repo)) }) { Text("Open repository") }
        }
        if (submitted.isEmpty()) Note("Search GitHub, including private repositories your connection can access.")
        else Group { Paged(submitted, load = { page -> require(page <= 34) { "GitHub search returns up to 1,000 results. Narrow your search." }; state.api.obj("/search/repositories", mapOf("q" to submitted, "page" to page.toString(), "per_page" to "30")).rows("items") }) { RepoRow(it) } }
    }
}

@Composable fun Inbox() {
    val state = LocalForge.current; val context = LocalContext.current; var unread by remember { mutableStateOf(true) }
    Screen {
        Row { FilterChip(unread, { unread = true }, { Text("Unread") }); Spacer(Modifier.width(8.dp)); FilterChip(!unread, { unread = false }, { Text("All") }) }
        Group { Paged(unread, load = { require(state.connected) { "Connect GitHub in Settings. Inbox requires OAuth or a classic token with notifications access." }; state.api.list("/notifications", it, mapOf("all" to (!unread).toString())) }) { notification ->
            Column {
                RowLink(notification.o("subject").s("title"), notification.o("repository").s("full_name") + if (notification.optBoolean("unread")) " · Unread" else "", R.drawable.ic_inbox) {
                    state.task {
                        if (notification.optBoolean("unread")) state.api.change("/notifications/threads/${positiveID(notification.s("id"))}", "PATCH")
                        val destination = route(notification.o("subject").s("url")) ?: Page("repo", notification.o("repository").s("name"), notification.o("repository").s("full_name"))
                        state.open(destination)
                    }
                }
                if (notification.optBoolean("unread")) TextButton(onClick = { state.task { state.api.change("/notifications/threads/${positiveID(notification.s("id"))}", "PATCH"); state.refresh++ } }) { Text("Mark as read") }
            }
        } }
    }
}
