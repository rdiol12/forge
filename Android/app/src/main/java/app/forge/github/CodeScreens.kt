package app.forge.github

import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

private data class Tree(val branch: String, val sha: String, val path: String, val content: Any)

@Composable fun FilesScreen(page: Page) {
    val state = LocalForge.current; var selected by rememberSaveable { mutableStateOf("") }; var picker by rememberSaveable { mutableStateOf(false) }; var search by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        Loaded(page to selected, load = {
            val api = state.api; val repo = repository(page.repo)
            var branch = selected.ifBlank { page.branch }; var sha = if (selected.isEmpty()) page.sha else ""; var path = page.arg
            if (page.kind == "codeLink") {
                require(safePath(page.arg)); val parts = page.arg.split('/'); var found = false
                if (validSha(parts[0])) { sha = parts[0]; path = parts.drop(1).joinToString("/"); branch = ""; found = true }
                else for (count in parts.size downTo 1) {
                    if (found) break
                    val candidate = parts.take(count).joinToString("/")
                    try {
                        val ref = api.obj("/repos/$repo/git/ref/heads/$candidate")
                        if (ref.s("ref") == "refs/heads/$candidate") { branch = candidate; sha = ref.o("object").s("sha"); path = parts.drop(count).joinToString("/"); found = true }
                    } catch (e: IllegalStateException) { if (!e.message.orEmpty().startsWith("Not found")) throw e }
                }
                require(found) { "This code link's branch or revision was not found." }
            } else {
                if (branch.isEmpty()) branch = api.obj("/repos/$repo").s("default_branch")
                if (sha.isEmpty()) { require(validBranch(branch)); sha = api.obj("/repos/$repo/git/ref/heads/$branch").o("object").s("sha") }
            }
            require(validSha(sha)) { "Could not verify the selected commit." }
            require(path.isEmpty() || safePath(path))
            val endpoint = if (page.kind == "readme") "/repos/$repo/readme" else "/repos/$repo/contents" + if (path.isEmpty()) "" else "/$path"
            Tree(branch, sha, path, api.request(endpoint, mapOf("ref" to sha)))
        }) { tree ->
            if (tree.content is JSONObject) {
                val file = tree.content
                if (file.s("type") == "file") FileScreen(Page("file", file.s("name"), page.repo, arg = file.s("path"), sha = file.s("sha"), branch = tree.branch))
                else Note("This entry is a submodule or link. Open its repository to browse it.")
            } else {
                Row(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { picker = true }) { Text(tree.branch.ifBlank { tree.sha.take(12) }) }
                    DownloadButton(DownloadSpec("/repos/${page.repo}/zipball/${tree.sha}", "${page.repo.substringAfter('/')}-${tree.branch.ifBlank { tree.sha.take(12) }}.zip"))
                }
                Note("${tree.path.ifBlank { page.repo }} · ${tree.sha.take(12)}")
                val files = (tree.content as JSONArray).objects().sortedWith(compareBy({ it.s("type") != "dir" }, { it.s("name").lowercase() }))
                LazyColumn(Modifier.fillMaxSize()) {
                    itemsIndexed(files, key = { _, item -> item.s("path") }) { _, file ->
                        val directory = file.s("type") == "dir"
                        RowLink(file.s("name"), if (directory) "Folder" else bytes(file.optLong("size")), if (directory) R.drawable.ic_repo else R.drawable.ic_tag) {
                            if (directory || file.s("type") == "file") state.open(Page(if (directory) "files" else "file", file.s("name"), page.repo, arg = file.s("path"), sha = if (directory) tree.sha else file.s("sha"), branch = tree.branch))
                            else state.notice = "Submodules and symbolic links are not editable files."
                        }
                        HorizontalDivider()
                    }
                    item { Note("GitHub lists up to 1,000 entries per folder. Download the ZIP for the complete repository at this commit.") }
                }
            }
        }
    }
    if (picker) AlertDialog(onDismissRequest = { picker = false }, title = { Text("Switch branch") }, text = {
        Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
            OutlinedTextField(search, { search = it }, label = { Text("Filter loaded branches") })
            Paged(page.repo, load = { state.api.list("/repos/${repository(page.repo)}/branches", it) }) { branch -> if (branch.s("name").contains(search, true)) TextButton(onClick = { selected = branch.s("name"); picker = false }) { Text(branch.s("name")) } }
        }
    }, confirmButton = { TextButton(onClick = { picker = false }) { Text("Done") } })
}

@Composable fun FileScreen(page: Page) {
    val clipboard = LocalClipboardManager.current
    val state = LocalForge.current; var edit by rememberSaveable { mutableStateOf(page.id == "edit") }; var preview by rememberSaveable { mutableStateOf(page.title.endsWith(".md", true) || page.title.startsWith("README", true)) }
    var savedText by remember(page.sha) { mutableStateOf<String?>(null) }; var sha by remember(page.sha) { mutableStateOf(page.sha) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            DownloadButton(DownloadSpec("/repos/${repository(page.repo)}/git/blobs/$sha", page.title, "application/vnd.github.raw+json"))
            TextButton(onClick = { clipboard.setText(AnnotatedString(page.arg)); state.notice = "File path copied." }) { Text("Copy path") }
            if (page.title.endsWith(".md", true) || page.title.startsWith("README", true) || page.title.endsWith(".json", true)) TextButton(onClick = { preview = !preview }) { Text(if (preview) "Source" else if (page.title.endsWith(".json", true)) "Format JSON" else "Preview") }
        }
        Loaded(page to sha, load = { savedText ?: state.api.blob(page.repo, sha) }) { original ->
            val text = savedText ?: original
            if (state.connected && page.branch.isNotBlank() && page.title.startsWith("README", true)) TextButton(onClick = { edit = true }, modifier = Modifier.padding(horizontal = 12.dp)) { Text("Edit README on ${page.branch}") }
            if (preview && !page.title.endsWith(".json", true)) Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) { Markdown(text) }
            else {
                val source = if (preview && page.title.endsWith(".json", true)) runCatching { if (text.trimStart().startsWith('[')) JSONArray(text).toString(2) else JSONObject(text).toString(2) }.getOrDefault(text) else text
                CodeReader(source, page.title)
            }
            if (edit) EditDialog("Edit ${page.title}", listOf(Field("File content", text, true), Field("Commit message", "Update ${page.title}")), "Commit directly to ${page.repo}, branch ${page.branch}. If the file changed since it was opened, GitHub will reject the save.", "Commit changes", dismiss = { edit = false }) { values ->
                require(safePath(page.arg))
                val result = state.api.change("/repos/${page.repo}/contents/${page.arg}", "PUT", fileEdit(sha, page.branch, values[0], values[1]))
                val next = result.o("content").s("sha"); require(validSha(next)) { "GitHub did not confirm the file revision. Refresh before retrying." }
                savedText = values[0]; sha = next
                if (state.stack.lastOrNull() == page) state.stack[state.stack.lastIndex] = page.copy(sha = next)
            }
        }
    }
}

@Composable fun CodeReader(source: String, filename: String) {
    var query by remember { mutableStateOf("") }; var wrap by remember { mutableStateOf(false) }; val clipboard = LocalClipboardManager.current
    val dark = isSystemInDarkTheme(); var lines by remember(source, dark) { mutableStateOf(emptyList<AnnotatedString>()) }
    val scroll = androidx.compose.foundation.lazy.rememberLazyListState(); val scope = rememberCoroutineScope()
    var match by remember { mutableIntStateOf(0) }
    val plainLines = remember(source) { source.replace("\r\n", "\n").replace('\r', '\n').lines() }
    val matches = remember(plainLines, query) { if (query.isEmpty()) emptyList() else plainLines.indices.filter { plainLines[it].contains(query, true) } }
    LaunchedEffect(source, dark) { lines = withContext(Dispatchers.Default) { highlight(source.replace("\r\n", "\n").replace('\r', '\n'), dark) } }
    LaunchedEffect(query) { match = 0; matches.firstOrNull()?.let { scroll.scrollToItem(it) } }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) {
        Row(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            TextButton(onClick = { clipboard.setText(AnnotatedString(source)) }) { Text("Copy") }
            FilterChip(wrap, { wrap = !wrap }, { Text("Wrap") })
            Text("${lines.size} lines", style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(12.dp))
        }
        OutlinedTextField(query, { query = it }, label = { Text("Find in file") }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp), trailingIcon = {
            if (matches.isNotEmpty()) TextButton(onClick = { match = (match + 1) % matches.size; scope.launch { scroll.animateScrollToItem(matches[match]) } }) { Text("${match + 1}/${matches.size} ↓") }
        })
        BoxWithConstraints(Modifier.weight(1f).padding(top = 8.dp)) {
            val width = if (wrap) maxWidth else maxOf(maxWidth, minOf(20_000.dp, ((source.lineSequence().maxOfOrNull { it.length } ?: 1) * 8.5f + 80).dp))
            // ponytail: lexical colors and a 20,000dp line canvas; Wrap or Copy handles unusually long generated lines.
            val modifier = if (wrap) Modifier else Modifier.horizontalScroll(rememberScrollState())
            Box(modifier) {
                LazyColumn(state = scroll, modifier = Modifier.width(width).fillMaxHeight()) {
                    itemsIndexed(lines) { index, line -> Row(Modifier.fillMaxWidth().background(if (index in matches) Color(0x33D4A72C) else Color.Transparent).padding(vertical = 2.dp)) {
                        Text("${index + 1}", color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = FontFamily.Monospace, fontSize = 13.sp, modifier = Modifier.width(52.dp).padding(end = 10.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End)
                        SelectionContainer { Text(if (line.isEmpty()) AnnotatedString(" ") else line, fontFamily = FontFamily.Monospace, fontSize = 13.sp, softWrap = wrap, modifier = Modifier.padding(end = 12.dp)) }
                    } }
                }
            }
        }
    }
}

fun highlight(source: String, dark: Boolean): List<AnnotatedString> {
    val builder = AnnotatedString.Builder(source)
    val pattern = Regex("/\\*[\\s\\S]*?\\*/|//[^\\n]*|(?m)^\\s*#[^\\n]*|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|\\b(?:fun|func|class|struct|enum|interface|val|var|let|const|import|package|return|if|else|when|switch|case|for|while|try|catch|throw|throws|async|await|suspend|public|private|internal|override|static|void|def|from|true|false|null|nil|self|this|guard|in|as|is|new)\\b|\\b\\d+(?:\\.\\d+)?\\b|\\b[A-Z][A-Za-z0-9_]*\\b")
    pattern.findAll(source).forEach { token ->
        val value = token.value.trimStart()
        val color = when { value.startsWith("//") || value.startsWith("/*") || value.startsWith('#') -> if (dark) 0xFF8B949EL else 0xFF57606AL; value.startsWith('"') || value.startsWith('\'') -> if (dark) 0xFFA5D6FFL else 0xFF0A3069L; value.firstOrNull()?.isDigit() == true -> if (dark) 0xFF79C0FFL else 0xFF0550AEL; value.firstOrNull()?.isUpperCase() == true -> if (dark) 0xFFFFA657L else 0xFF953800L; else -> if (dark) 0xFFFF7B72L else 0xFFCF222EL }
        builder.addStyle(SpanStyle(color = Color(color)), token.range.first, token.range.last + 1)
    }
    val full = builder.toAnnotatedString(); var offset = 0
    return source.split('\n').map { line -> full.subSequence(offset, offset + line.length).also { offset += line.length + 1 } }
}

@Composable fun Markdown(source: String) {
    val state = LocalForge.current; val context = LocalContext.current
    val linkColor = MaterialTheme.colorScheme.primary
    val blocks = remember(source) { markdownBlocks(source) }
    val positions = remember(source) { blocks.map { BringIntoViewRequester() } }
    val scope = rememberCoroutineScope()
    var contents by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (blocks.any { it.first.startsWith("h") }) Box {
            TextButton(onClick = { contents = true }) { Text("Contents") }
            DropdownMenu(contents, onDismissRequest = { contents = false }) { blocks.forEachIndexed { index, (kind, title) ->
                if (kind.startsWith("h")) DropdownMenuItem(text = { Text(title) }, onClick = { contents = false; scope.launch { positions[index].bringIntoView() } })
            } }
        }
        blocks.forEachIndexed { index, (kind, text) ->
        Column(Modifier.bringIntoViewRequester(positions[index])) {
        when {
            kind == "code" -> Box(Modifier.heightIn(min = 160.dp, max = 300.dp).height(250.dp)) { CodeReader(text, "snippet") }
            kind.startsWith("h") -> Text(text, style = when (kind) { "h1" -> MaterialTheme.typography.headlineMedium; "h2" -> MaterialTheme.typography.headlineSmall; else -> MaterialTheme.typography.titleMedium }, fontWeight = FontWeight.Bold)
            kind == "rule" -> HorizontalDivider()
            else -> {
                val rich = buildAnnotatedString {
                    val pattern = Regex("\\[([^]]+)\\]\\((https://[^)]+)\\)|\\*\\*([^*]+)\\*\\*|`([^`]+)`")
                    var end = 0
                    pattern.findAll(text).forEach { token ->
                        append(text.substring(end, token.range.first))
                        when {
                            token.groupValues[1].isNotEmpty() -> withLink(LinkAnnotation.Url(token.groupValues[2], TextLinkStyles(SpanStyle(color = linkColor)), linkInteractionListener = { state.link(context, token.groupValues[2]) })) { append(token.groupValues[1]) }
                            token.groupValues[3].isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(token.groupValues[3]) }
                            else -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(token.groupValues[4]) }
                        }; end = token.range.last + 1
                    }; append(text.substring(end))
                }
                SelectionContainer { Text(rich, style = MaterialTheme.typography.bodyMedium, color = if (kind == "quote") MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface) }
            }
        }
    } } }
}

fun markdownBlocks(source: String): List<Pair<String, String>> {
    val result = mutableListOf<Pair<String, String>>(); val paragraph = mutableListOf<String>(); val code = mutableListOf<String>(); var fence: String? = null
    fun flush() { if (paragraph.isNotEmpty()) { result.add("text" to paragraph.joinToString("\n")); paragraph.clear() } }
    source.lines().forEach { line ->
        val trimmed = line.trimStart()
        if (fence != null) { if (trimmed.startsWith(fence!!)) { result.add("code" to code.joinToString("\n")); code.clear(); fence = null } else code.add(line) }
        else when {
            trimmed.startsWith("```") || trimmed.startsWith("~~~") -> { flush(); fence = trimmed.take(3) }
            Regex("#{1,6} .*?").matches(trimmed) -> { flush(); result.add("h${trimmed.takeWhile { it == '#' }.length}" to trimmed.substringAfter(' ')) }
            trimmed in listOf("---", "***", "___") -> { flush(); result.add("rule" to "") }
            trimmed.startsWith("> ") -> { flush(); result.add("quote" to trimmed.drop(2)) }
            trimmed.startsWith("- ") || trimmed.startsWith("* ") -> { flush(); result.add("text" to "• ${trimmed.drop(2)}") }
            trimmed.isEmpty() -> flush()
            else -> paragraph.add(line)
        }
    }
    flush(); if (fence != null) result.add("code" to code.joinToString("\n")); return result
}
