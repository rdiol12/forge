package app.forge.github

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    private val state: ForgeState by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        intent.dataString?.let(state::callback)
        setContent { ForgeTheme { ForgeApp(state) } }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); intent.dataString?.let(state::callback) }
    override fun onResume() { super.onResume(); state.downloads.refresh() }
}

@Composable fun ForgeTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (dark) darkColorScheme(primary = Color(0xFF58A6FF), background = Color(0xFF010409), surface = Color(0xFF0D1117), surfaceContainer = Color(0xFF161B22), outlineVariant = Color(0xFF30363D))
        else lightColorScheme(primary = Color(0xFF0969DA), background = Color(0xFFF6F8FA), surface = Color.White, surfaceContainer = Color(0xFFF6F8FA), outlineVariant = Color(0xFFD0D7DE)), content = content)
}

val LocalForge = staticCompositionLocalOf<ForgeState> { error("Missing Forge state") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun ForgeApp(state: ForgeState) {
    CompositionLocalProvider(LocalForge provides state) {
        val titles = listOf("Home", "Inbox", "Explore", "Profile")
        val icons = listOf(R.drawable.ic_home, R.drawable.ic_inbox, R.drawable.ic_telescope, R.drawable.ic_person)
        val page = state.stack.lastOrNull()
        var homeMenu by remember { mutableStateOf(false) }
        val snack = remember { SnackbarHostState() }
        LaunchedEffect(state.notice) { state.notice?.let { snack.showSnackbar(it); state.notice = null } }
        BackHandler(page != null) { state.back() }
        Scaffold(
            topBar = { if (page?.kind != "newIssue") TopAppBar(title = { Text(page?.title ?: titles[state.tab], maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Bold) },
                navigationIcon = { if (page != null) TextButton(onClick = state::back, modifier = Modifier.semanticsLabel("Back")) { Text("‹", style = MaterialTheme.typography.headlineLarge) } },
                actions = {
                    IconButton(onClick = { state.refresh++ }) { Text("↻", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.semanticsLabel("Refresh")) }
                    if (page == null && state.tab == 0) {
                        Box {
                            IconButton(onClick = { homeMenu = true }, modifier = Modifier.semanticsLabel("Create or add")) { Text("+", style = MaterialTheme.typography.headlineMedium) }
                            DropdownMenu(homeMenu, { homeMenu = false }) {
                                DropdownMenuItem(text = { Text("New issue") }, enabled = state.connected, onClick = { homeMenu = false; state.open(Page("issueRepo", "New issue")) })
                                DropdownMenuItem(text = { Text("Add favorite") }, onClick = { homeMenu = false; state.chooseTab(2) })
                                DropdownMenuItem(text = { Text("Settings") }, onClick = { homeMenu = false; state.open(Page("settings", "Settings")) })
                            }
                        }
                        IconButton(onClick = { state.chooseTab(3) }, modifier = Modifier.semanticsLabel("Your profile")) { Avatar(state.account, 28) }
                    } else if (page?.kind != "settings") TextButton(onClick = { state.open(Page("settings", "Settings")) }) { Text("Settings") }
                }) },
            bottomBar = { if (page?.kind != "newIssue") NavigationBar(containerColor = MaterialTheme.colorScheme.surface) { titles.forEachIndexed { index, title ->
                NavigationBarItem(selected = state.tab == index, onClick = { state.chooseTab(index) }, icon = { Icon(painterResource(icons[index]), title, Modifier.size(24.dp)) }, label = { Text(title) })
            } } }, snackbarHost = { SnackbarHost(snack) }
        ) { padding ->
            Box(Modifier.padding(padding).fillMaxSize()) {
                key(state.generation, page, state.tab) {
                    if (page != null) Destination(page)
                    else when (state.tab) { 0 -> Home(); 1 -> Inbox(); 2 -> RepositorySearch(); else -> if (state.connected) Profile(state.account) else Settings() }
                }
            }
        }
    }
}

fun Modifier.semanticsLabel(label: String) = this.then(Modifier.semantics { contentDescription = label })

@Composable fun Screen(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp), content = content)
}
@Composable fun Group(title: String = "", content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (title.isNotBlank()) Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 12.dp, start = 4.dp))
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surface), content = content)
    }
}
@Composable fun RowLink(title: String, subtitle: String = "", icon: Int = R.drawable.ic_repo, color: Color = MaterialTheme.colorScheme.primary, action: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = action).padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(34.dp).clip(RoundedCornerShape(8.dp)).background(color.copy(alpha = .12f)), contentAlignment = Alignment.Center) { Icon(painterResource(icon), null, Modifier.size(23.dp), tint = color) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
            if (subtitle.isNotBlank()) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text("›", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable fun Note(text: String) { Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(12.dp)) }
@Composable fun ErrorText(text: String) { Text(text, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(12.dp)) }
@Composable fun Loading() { Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp); Text("Loading…") } }

@Composable fun <T : Any> Loaded(id: Any = Unit, load: suspend () -> T, content: @Composable (T) -> Unit) {
    val state = LocalForge.current
    var value by remember(id) { mutableStateOf<T?>(null) }; var error by remember(id) { mutableStateOf<String?>(null) }; var busy by remember(id) { mutableStateOf(true) }
    LaunchedEffect(id, state.refresh, state.generation) {
        busy = true; error = null
        try { value = load() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message ?: "Could not load this content." } finally { busy = false }
    }
    if (busy) Loading()
    error?.let { ErrorText(it); TextButton(onClick = { state.refresh++ }) { Text("Retry") } }
    value?.let { content(it) }
}

@Composable fun Paged(id: Any = Unit, order: Comparator<JSONObject>? = null, load: suspend (Int) -> List<JSONObject>, row: @Composable (JSONObject) -> Unit) {
    val state = LocalForge.current; val scope = rememberCoroutineScope()
    var rows by remember(id) { mutableStateOf(emptyList<JSONObject>()) }; var page by remember(id) { mutableIntStateOf(0) }
    var more by remember(id) { mutableStateOf(false) }; var busy by remember(id) { mutableStateOf(false) }; var error by remember(id) { mutableStateOf<String?>(null) }
    suspend fun fetch(reset: Boolean) {
        if (busy) return; busy = true; error = null
        try {
            val next = if (reset) 1 else page + 1; val result = load(next)
            rows = (if (reset) result else rows + result).distinctBy { it.s("id").ifBlank { it.s("node_id").ifBlank { it.toString() } } }
            order?.let { rows = rows.sortedWith(it) }
            page = next; more = result.size == 30
        } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message ?: "Could not load this page." } finally { busy = false }
    }
    LaunchedEffect(id, state.refresh, state.generation) { fetch(true) }
    Column {
        rows.forEach { row(it); HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .5f)) }
        if (busy) Loading()
        if (!busy && rows.isEmpty() && error == null) Note("Nothing here yet.")
        error?.let { ErrorText(it); TextButton(onClick = { scope.launch { fetch(page == 0) } }) { Text("Retry") } }
        if (more && !busy) TextButton(onClick = { scope.launch { fetch(false) } }, modifier = Modifier.fillMaxWidth()) { Text("Load more") }
    }
}

data class Field(val label: String, val initial: String = "", val multiline: Boolean = false, val toggle: Boolean = false)
@Composable fun EditDialog(title: String, fields: List<Field>, explanation: String = "", confirm: String = "Save", required: String? = null, dismiss: () -> Unit, save: suspend (List<String>) -> Unit) {
    val state = LocalForge.current
    val key = "${state.generation}:${state.tab}:${state.stack.lastOrNull()}:$title"
    // Keep large drafts and in-flight saves in the ViewModel, never in Android's size-limited saved-state Bundle.
    val draft = remember(key) { state.drafts.getOrPut(key) { EditorDraft(fields.map { it.initial }, explanation, save) } }
    val values = draft.values; val busy = draft.busy; val error = draft.error
    var typed by remember { mutableStateOf("") }; var discard by remember { mutableStateOf(false) }
    fun dismissDraft() { state.drafts.remove(key); dismiss() }
    if (draft.saved) { LaunchedEffect(key) { dismiss() }; return }
    fun close() { if (!busy) { if (values.toList() != draft.initial) discard = true else dismissDraft() } }
    AlertDialog(onDismissRequest = ::close, title = { Text(title) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (draft.explanation.isNotBlank()) Text(draft.explanation)
            fields.forEachIndexed { i, field ->
                if (field.toggle) Row(verticalAlignment = Alignment.CenterVertically) { Text(field.label, Modifier.weight(1f)); Switch(values[i].toBoolean(), { values[i] = it.toString() }, enabled = !busy) }
                else OutlinedTextField(values[i], { values[i] = it }, label = { Text(field.label) }, singleLine = !field.multiline, minLines = if (field.multiline) 4 else 1, maxLines = if (field.multiline) 10 else 1, enabled = !busy, modifier = Modifier.fillMaxWidth())
            }
            if (required != null) OutlinedTextField(typed, { typed = it }, label = { Text("Type $required") }, enabled = !busy)
            if (busy) Loading(); error?.let { ErrorText(it) }
        }
    }, confirmButton = { TextButton(enabled = !busy && (required == null || typed == required), onClick = {
        state.task { draft.busy = true; draft.error = null
            try { draft.save(values.toList()); state.drafts.remove(key); state.refresh++; draft.saved = true } catch (e: CancellationException) { throw e } catch (e: Exception) { draft.error = e.message ?: "Could not confirm the change." } finally { draft.busy = false }
        }
    }) { Text(confirm) } }, dismissButton = { TextButton(onClick = ::close, enabled = !busy) { Text("Cancel") } })
    if (discard) AlertDialog(onDismissRequest = { discard = false }, title = { Text("Discard changes?") }, text = { Text("Your draft has not been saved.") }, confirmButton = { TextButton(onClick = ::dismissDraft) { Text("Discard") } }, dismissButton = { TextButton(onClick = { discard = false }) { Text("Keep editing") } })
}

@Composable fun Destination(page: Page) {
    when (page.kind) {
        "home" -> Home()
        "licenses" -> { val context = androidx.compose.ui.platform.LocalContext.current; Screen { Note(remember { context.assets.open("ThirdPartyNotices.txt").bufferedReader().use { it.readText() } }) } }
        "settings" -> Settings()
        "repo" -> RepositoryScreen(page.repo, page.branch)
        "community" -> RepositoryCommunity(page)
        "license" -> RepositoryLicense(page.repo)
        "commits" -> CommitsScreen(page)
        "commit" -> CommitScreen(page)
        "deletedCommits" -> DeletedCommits(page.repo)
        "restoreCommit" -> RestoreCommit(page)
        "issueRepo" -> IssueRepositoryPicker()
        "newIssue" -> IssueComposer(page.repo)
        "repos" -> Repositories(page)
        "profile" -> Profile(page.id)
        "people" -> People(page)
        "orgs" -> Organizations(page.id)
        "actions", "latest" -> Runs(page)
        "ownedActions" -> OwnedActions()
        "run" -> RunDetail(page)
        "log" -> LogScreen(page)
        "releases" -> Releases(page.repo)
        "release" -> ReleaseScreen(page)
        "files", "readme", "codeLink" -> FilesScreen(page)
        "releaseTag" -> { val state = LocalForge.current; Loaded(page, load = { state.api.obj("/repos/${repository(page.repo)}/releases/tags/${page.arg}") }) { ReleaseScreen(page.copy(kind = "release", id = it.s("id"))) } }
        "file" -> FileScreen(page)
        "repoSettings" -> RepositorySettings(page.repo)
        "conversations" -> Conversations(page)
        "issue", "pull", "discussion" -> ConversationScreen(page)
        "diffs" -> PullFiles(page)
        "threads" -> ReviewThreads(page)
        "thread" -> ReviewThreadScreen(page)
        "replies" -> DiscussionReplies(page)
        "downloads" -> DownloadScreen()
        else -> Screen { Note("This screen is unavailable.") }
    }
}
