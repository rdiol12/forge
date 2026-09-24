package app.forge.github

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

fun issueFields(title: String, body: String, assignees: List<String> = emptyList(), labels: List<String> = emptyList(), milestone: Int? = null): JSONObject {
    require(title.trim().isNotEmpty() && title.trim().length <= 256 && assignees.all(::validLogin) && assignees.size <= 10 && (milestone == null || milestone > 0)) { "Enter a title and valid issue metadata." }
    return json("title" to title.trim(), "body" to body).apply {
        if (assignees.isNotEmpty()) put("assignees", JSONArray(assignees))
        if (labels.isNotEmpty()) put("labels", JSONArray(labels))
        milestone?.let { put("milestone", it) }
    }
}

fun htmlEscape(value: String) = value.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;").replace(">", "&gt;")

class ReadmeDocument(source: String, val repo: String, val sha: String, val path: String) {
    val html: String
    val base: String get() = URI("https", "github.com", "/$repo/blob/$sha/$path", null).toASCIIString()
    init {
        repository(repo); require(sha.matches(Regex("[a-fA-F0-9]{40}"))); require(safePath(path))
        val base = URI("https", "raw.githubusercontent.com", "/$repo/$sha/$path", null)
        val clean = source.replace(Regex("""\s+srcset\s*=\s*(?:"[^"]*"|'[^']*')""", RegexOption.IGNORE_CASE), "")
        html = Regex("""\bsrc\s*=\s*(["'])(.*?)\1""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).replace(clean) { match ->
            val location = runCatching {
                val uri = base.resolve(match.groupValues[2].replace("&amp;", "&")).normalize()
                require(uri.scheme == "https" && uri.userInfo == null && uri.port in listOf(-1, 443))
                val rawPrefix = "/$repo/$sha/"; val webPrefix = "/$repo/raw/$sha/"
                val image = when {
                    uri.host == "raw.githubusercontent.com" && uri.path.startsWith(rawPrefix) -> uri.path.removePrefix(rawPrefix)
                    uri.host == "github.com" && uri.path.startsWith(webPrefix) -> uri.path.removePrefix(webPrefix)
                    else -> null
                }
                if (image != null) URI("forge-readme", "image", "/$image", null).toASCIIString() else uri.toASCIIString()
            }.getOrDefault("")
            "src=\"${htmlEscape(location)}\""
        }
    }
    fun imagePath(uri: URI): String? = runCatching {
        require(uri.scheme == "forge-readme" && uri.host == "image" && uri.userInfo == null && uri.port == -1 && uri.query == null)
        uri.path.removePrefix("/").also { require(safePath(it)) }
    }.getOrNull()
    fun page(dark: Boolean): String = """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src https: forge-readme:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><style>
        :root{color-scheme:${if(dark) "dark" else "light"}}body{margin:0;padding:16px;font:16px -apple-system,BlinkMacSystemFont,Roboto,sans-serif;line-height:1.55;overflow-wrap:anywhere;color:${if(dark) "#e6edf3" else "#1f2328"};background:${if(dark) "#0d1117" else "white"}}img,video{max-width:100%;height:auto}h1,h2{border-bottom:1px solid #8886;padding-bottom:.3em}a{color:${if(dark) "#58a6ff" else "#0969da"}}pre{overflow:auto;padding:12px;background:${if(dark) "#161b22" else "#f6f8fa"};border-radius:8px}code{font-family:ui-monospace,monospace;font-size:.86em}table{display:block;overflow:auto;border-collapse:collapse}td,th{border:1px solid #8886;padding:6px 12px}blockquote{margin-left:0;border-left:3px solid #8886;padding-left:16px;color:#888}svg{max-width:100%}.anchor{display:none}input{pointer-events:none}
        </style></head><body>$html</body></html>"""
}

suspend fun GitHub.data(path: String, query: Map<String, String> = emptyMap(), accept: String = "application/vnd.github.raw+json", limit: Int = 8_388_608): ByteArray = withContext(Dispatchers.IO) {
    var uri = apiUrl(path, query)
    val key = "$token\n$uri\n$accept"; val epoch = cache?.epoch ?: 0; val old = cache?.value(key)
    if (old?.fresh == true) return@withContext old.bytes
    repeat(6) {
        val c = connection(uri, accept)
        old?.etag?.let { c.setRequestProperty("If-None-Match", it) }
        try {
            if (c.responseCode == 304 && old != null) { cache?.store(key, old.bytes, c.getHeaderField("ETag") ?: old.etag, epoch, c.getHeaderField("Cache-Control") ?: old.control); return@withContext old.bytes }
            if (c.responseCode in listOf(301, 302, 307, 308)) {
                val next = uri.resolve(c.getHeaderField("Location") ?: error("Missing redirect."))
                require(next.host == "api.github.com" && trustedDownload(next)) { "Unexpected API redirect." }; uri = next
            } else {
                require(c.responseCode in 200..299) { "GitHub returned HTTP ${c.responseCode}. Check access or retry." }
                return@withContext c.inputStream.use { it.readLimited(limit + 1) }.also {
                    require(it.size <= limit) { "This preview is too large. Download the file instead." }
                    cache?.store(key, it, c.getHeaderField("ETag"), epoch, c.getHeaderField("Cache-Control") ?: "")
                }
            }
        } finally { c.disconnect() }
    }
    error("Too many redirects.")
}

suspend fun GitHub.readme(repo: String, sha: String): Pair<JSONObject, ReadmeDocument> {
    repository(repo); require(validSha(sha))
    val query = mapOf("ref" to sha); val file = obj("/repos/$repo/readme", query)
    require(file.optLong("size") <= 1_048_576) { "This README is over 1 MiB. Open Code to download the full file." }
    val html = data("/repos/$repo/readme", query, "application/vnd.github.html+json", 4_194_304).toString(Charsets.UTF_8)
    return file to ReadmeDocument(html, repo, sha, file.s("path"))
}

suspend fun GitHub.profileHighlights(login: String) = gql("""query(${'$'}login:String!){user(login:${'$'}login){isEmployee isDeveloperProgramMember isGitHubStar isCampusExpert pinnedItems(first:6,types:[REPOSITORY]){nodes{... on Repository{nameWithOwner description stargazerCount}}}}}""", json("login" to accountPath(login))).o("user")

suspend fun GitHub.isStarred(repo: String): Boolean = withContext(Dispatchers.IO) {
    if (token.isBlank()) return@withContext false
    val c = connection(apiUrl("/user/starred/${repository(repo)}"))
    try { if (c.responseCode == 404) false else { require(c.responseCode == 204) { "Couldn't load your star status." }; true } } finally { c.disconnect() }
}

suspend fun GitHub.editDescription(repo: String, original: String, description: String) {
    cache?.clear()
    val current = obj("/repos/${repository(repo)}")
    require(current.o("permissions").optBoolean("admin") && current.s("description") == original) { "Only administrators can edit descriptions. Refresh if it changed elsewhere." }
    change("/repos/$repo", "PATCH", json("description" to description))
}

data class IssueOption(val id: String, val title: String, val detail: String = "")
data class IssueOptionPage(val items: List<IssueOption>, val more: Boolean, val cursor: String = "")

suspend fun GitHub.issueOptions(repo: String, kind: String, page: Int, cursor: String): IssueOptionPage {
    val prefix = "/repos/${repository(repo)}"
    if (kind == "Project") {
        val parts = repo.split('/')
        val connection = gql("""query(${'$'}owner:String!,${'$'}name:String!,${'$'}cursor:String){repository(owner:${'$'}owner,name:${'$'}name){projectsV2(first:30,after:${'$'}cursor){nodes{id title closed}pageInfo{hasNextPage endCursor}}}}""", json("owner" to parts[0], "name" to parts[1], "cursor" to cursor.ifBlank { null })).o("repository").getJSONObject("projectsV2")
        return IssueOptionPage(connection.rows("nodes").filter { !it.optBoolean("closed") }.map { IssueOption(it.s("id"), it.s("title")) }, connection.o("pageInfo").optBoolean("hasNextPage"), connection.o("pageInfo").s("endCursor"))
    }
    val route = when(kind) { "Assignees" -> "assignees"; "Labels" -> "labels"; "Milestone" -> "milestones"; else -> error("Unknown issue field.") }
    val rows = list("$prefix/$route", page, if (kind == "Milestone") mapOf("state" to "open") else emptyMap())
    return IssueOptionPage(rows.map { row -> when(kind) {
        "Assignees" -> IssueOption(row.s("login"), row.s("login"))
        "Labels" -> IssueOption(row.s("name"), row.s("name"), row.s("description"))
        else -> IssueOption(row.s("number"), row.s("title"), row.s("description"))
    } }, rows.size == 30)
}

suspend fun GitHub.addIssueToProject(issueID: String, projectID: String) {
    val result = gql("""mutation(${'$'}project:ID!,${'$'}issue:ID!){addProjectV2ItemById(input:{projectId:${'$'}project,contentId:${'$'}issue}){item{id}}}""", json("project" to projectID, "issue" to issueID))
    require(result.o("addProjectV2ItemById").o("item").s("id").isNotBlank()) { "GitHub did not confirm project assignment." }
}

suspend fun GitHub.editProfile(original: JSONObject, fields: Map<String, String>, hireable: Boolean) {
    val allowed = setOf("name", "bio", "blog", "company", "location", "twitter_username")
    require(fields.keys.all { it in allowed } && (fields["bio"]?.length ?: 0) <= 160) { "Keep the bio within 160 characters." }
    cache?.clear()
    val current = obj("/user"); require(current.s("login") == original.s("login")) { "Your account changed. Reopen the editor." }
    val changes = JSONObject()
    fields.forEach { (key, value) -> if (value != original.s(key)) {
        require(current.s(key) == original.s(key)) { "Your profile changed elsewhere. Refresh before saving." }; changes.put(key, value)
    } }
    if (hireable != original.optBoolean("hireable")) {
        require(current.optBoolean("hireable") == original.optBoolean("hireable")) { "Your profile changed elsewhere. Refresh before saving." }
        changes.put("hireable", hireable)
    }
    if (changes.length() > 0) change("/user", "PATCH", changes)
}

suspend fun GitHub.isFollowing(login: String): Boolean = withContext(Dispatchers.IO) {
    val c = connection(apiUrl("/user/following/${accountPath(login)}"))
    try { if (c.responseCode == 404) false else { require(c.responseCode == 204) { "Couldn't load your follow status." }; true } } finally { c.disconnect() }
}
