package app.forge.github

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject

class IssueDraft {
    var title by mutableStateOf("")
    var body by mutableStateOf("")
    val selections = mutableStateMapOf<String, List<IssueOption>>()
    var created by mutableStateOf<JSONObject?>(null)
    var warning by mutableStateOf<String?>(null)
    var error by mutableStateOf<String?>(null)
    var busy by mutableStateOf(false)
    var projectPending by mutableStateOf(false)
}

@Composable fun IssueRepositoryPicker() {
    val state = LocalForge.current; var query by remember { mutableStateOf("") }
    fun open(repo: String) { state.open(Page("newIssue", "Create new issue", repository(repo))) }
    Screen {
        OutlinedTextField(query, { query = it }, label = { Text("Filter loaded repositories") }, modifier = Modifier.fillMaxWidth())
        Group("Your repositories") {
            Paged(load = { state.api.list("/user/repos", it, mapOf("affiliation" to "owner", "sort" to "updated")) }) { repo ->
                if (repo.s("full_name").contains(query, true)) RowLink(repo.s("full_name")) { open(repo.s("full_name")) }
            }
        }
        Group("Favorites") { state.favorites.filter { it.contains(query, true) }.forEach { repo -> RowLink(repo) { open(repo) } } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun IssueComposer(repo: String) {
    val state = LocalForge.current
    val key = "${state.generation}:$repo"
    val draft = remember(key) { state.issueDrafts.getOrPut(key) { IssueDraft() } }
    var picker by remember { mutableStateOf<String?>(null) }
    var discard by remember { mutableStateOf(false) }
    fun done() {
        state.issueDrafts.remove(key); state.back()
        draft.created?.let { state.open(Page("issue", "#${it.optInt("number")}", repo, it.s("number"))) }
    }
    fun close() { if (!draft.busy) { if (draft.created != null || (draft.title.isBlank() && draft.body.isBlank() && draft.selections.values.all { it.isEmpty() })) done() else discard = true } }
    fun submit() {
        draft.busy = true; draft.error = null
        val api = state.api
        state.task {
            try {
                if (draft.created == null) {
                    val assignees = draft.selections["Assignees"].orEmpty().map { it.id }
                    val labels = draft.selections["Labels"].orEmpty().map { it.id }
                    val milestone = draft.selections["Milestone"]?.firstOrNull()?.id?.toInt()
                    val item = api.change("/repos/${repository(repo)}/issues", body = issueFields(draft.title, draft.body, assignees, labels, milestone))
                    draft.created = item
                    if (!item.rows("assignees").map { it.s("login") }.containsAll(assignees) || !item.rows("labels").map { it.s("name") }.containsAll(labels) || (milestone != null && item.o("milestone").optInt("number") != milestone)) draft.warning = "Issue created. GitHub did not apply every selected field; check your repository permissions."
                    draft.projectPending = !draft.selections["Project"].isNullOrEmpty()
                }
                if (draft.projectPending) {
                    api.addIssueToProject(draft.created!!.getString("node_id"), draft.selections["Project"]!!.first().id)
                    draft.projectPending = false
                }
                state.refresh++
                if (draft.warning == null) done()
            } catch (e: Exception) { draft.error = if (draft.created != null) "Issue created, but project assignment failed: ${e.message}. Retry only updates the project." else e.message }
            finally { draft.busy = false }
        }
    }
    BackHandler { close() }
    Scaffold(topBar = {
        CenterAlignedTopAppBar(title = { Text("Create new issue", style = MaterialTheme.typography.titleMedium) }, navigationIcon = { TextButton(enabled = !draft.busy, onClick = ::close) { Text("Cancel") } }, actions = {
            TextButton(enabled = !draft.busy && (draft.title.isNotBlank() || draft.created != null), onClick = { if (draft.created == null) submit() else done() }) { Text(if (draft.created == null) "Submit" else "Done") }
        })
    }, bottomBar = {
        Surface(tonalElevation = 3.dp, shadowElevation = 4.dp) {
            Row(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().horizontalScroll(rememberScrollState()).padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("Assignees", "Labels", "Milestone", "Project").forEach { field ->
                    val selected = draft.selections[field].orEmpty()
                    FilterChip(selected.isNotEmpty(), { picker = field }, { Text(field + if (selected.isEmpty()) "" else " (${selected.size})") }, enabled = !draft.busy && draft.created == null)
                }
            }
        }
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) { Avatar(repo.substringBefore('/'), 28); Text(repo) }
            OutlinedTextField(draft.title, { draft.title = it }, label = { Text("Title") }, enabled = !draft.busy && draft.created == null, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(draft.body, { draft.body = it }, label = { Text("Leave a comment") }, minLines = 10, enabled = !draft.busy && draft.created == null, modifier = Modifier.fillMaxWidth())
            if (draft.busy) Loading()
            draft.warning?.let { Note(it) }; draft.error?.let { ErrorText(it) }
            if (draft.projectPending && draft.created != null) Button(enabled = !draft.busy, onClick = ::submit) { Text("Retry project assignment") }
        }
    }
    picker?.let { field -> IssueOptionPicker(repo, field, draft.selections[field].orEmpty(), { picker = null }) { draft.selections[field] = it } }
    if (discard) AlertDialog(onDismissRequest = { discard = false }, title = { Text("Discard issue draft?") }, confirmButton = { TextButton(onClick = ::done) { Text("Discard") } }, dismissButton = { TextButton(onClick = { discard = false }) { Text("Keep editing") } })
}

@Composable private fun IssueOptionPicker(repo: String, field: String, selected: List<IssueOption>, dismiss: () -> Unit, select: (List<IssueOption>) -> Unit) {
    val state = LocalForge.current; val scope = rememberCoroutineScope()
    var options by remember { mutableStateOf(emptyList<IssueOption>()) }; var query by remember { mutableStateOf("") }
    var page by remember { mutableIntStateOf(0) }; var cursor by remember { mutableStateOf("") }; var more by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }
    suspend fun load() {
        busy = true; error = null
        try { val result = state.api.issueOptions(repo, field, page + 1, cursor); options = (options + result.items).distinctBy { it.id }; page++; cursor = result.cursor; more = result.more }
        catch (e: Exception) { error = e.message } finally { busy = false }
    }
    LaunchedEffect(repo, field) { load() }
    AlertDialog(onDismissRequest = dismiss, title = { Text(field) }, text = {
        Column(Modifier.heightIn(max = 460.dp).verticalScroll(rememberScrollState())) {
            OutlinedTextField(query, { query = it }, label = { Text("Filter loaded options") })
            TextButton(onClick = { select(emptyList()) }) { Text("Clear selection") }
            options.filter { it.title.contains(query, true) }.forEach { option ->
                val checked = selected.any { it.id == option.id }
                Row(Modifier.fillMaxWidth().clickable {
                    if (checked) select(selected.filter { it.id != option.id })
                    else if (field in listOf("Milestone", "Project")) select(listOf(option))
                    else if (field != "Assignees" || selected.size < 10) select(selected + option)
                }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked, null); Column { Text(option.title); if (option.detail.isNotBlank()) Text(option.detail, style = MaterialTheme.typography.bodySmall) }
                }
            }
            if (busy) Loading()
            error?.let { ErrorText(it) }
            if (!busy && (more || error != null)) TextButton(onClick = { scope.launch { load() } }) { Text(if (error != null) "Retry" else "Load more") }
            if (!busy && options.isEmpty() && error == null) Note("No available ${field.lowercase()}.")
        }
    }, confirmButton = { TextButton(onClick = dismiss) { Text("Done") } })
}
