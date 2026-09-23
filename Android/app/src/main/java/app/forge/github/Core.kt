package app.forge.github

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

fun validLogin(value: String) = Regex("[A-Za-z0-9][A-Za-z0-9-]{0,38}").matches(value)
fun accountPath(value: String): String { require(validLogin(value)) { "Invalid GitHub account." }; return value }
fun repository(value: String): String {
    val parts = value.trim().split('/')
    require(parts.size == 2 && validLogin(parts[0]) && Regex("[A-Za-z0-9_.-]{1,100}").matches(parts[1]) && parts[1] !in listOf(".", "..")) { "Enter a repository as owner/name." }
    return parts.joinToString("/")
}
fun positiveID(value: String): String { require(Regex("[0-9]+").matches(value) && (value.toLongOrNull() ?: 0) > 0) { "Invalid GitHub identifier." }; return value }
fun validSha(value: String) = Regex("(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})").matches(value)
fun validBranch(value: String): Boolean = value.isNotBlank() && value !in listOf("@", "HEAD") && !value.startsWith('-') && !value.startsWith("refs/") && !value.endsWith('.') && !value.contains("..") && !value.contains("@{") && value.none { it.code <= 32 || it.code == 127 || it in "~^:?*[\\" } && value.split('/').all { it.isNotEmpty() && !it.startsWith('.') && !it.endsWith(".lock") }
fun safePath(value: String) = value.isNotBlank() && !value.startsWith('/') && !value.contains('\\') && value.split('/').none { it.isBlank() || it == "." || it == ".." } && value.none { it.code < 32 }
fun encode(value: String): String = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
fun apiUrl(path: String, query: Map<String, String> = emptyMap()): URI {
    require(path.startsWith('/') && !path.startsWith("//") && !path.contains('\\') && path.none { it.code < 32 } && path.split('/').none { it == "." || it == ".." }) { "Invalid GitHub API path." }
    val base = URI("https", null, "api.github.com", -1, path, null, null).toASCIIString()
    return URI(base + if (query.isEmpty()) "" else query.entries.joinToString("&", "?") { "${encode(it.key)}=${encode(it.value)}" })
}
fun trustedDownload(uri: URI): Boolean {
    val host = uri.host?.lowercase() ?: return false
    return uri.scheme == "https" && uri.rawUserInfo == null && uri.port in listOf(-1, 443) && (host in listOf("api.github.com", "github.com", "codeload.github.com") || host.endsWith(".githubusercontent.com") || host.endsWith(".blob.core.windows.net"))
}
fun backgroundLocation(uri: URI) = trustedDownload(uri) && !uri.host.equals("api.github.com", true)
fun safeName(value: String): String {
    var result = value.map { if (it.code < 32 || it.code == 127 || it in "/\\:") '_' else it }.joinToString("").trim()
    while (result.toByteArray().size > 180) result = result.dropLast(if (result.last().isLowSurrogate()) 2 else 1)
    return result.takeUnless { it.isBlank() || it in listOf(".", "..") } ?: "download"
}
fun InputStream.readLimited(limit: Int): ByteArray {
    val output = ByteArrayOutputStream(); val buffer = ByteArray(8192)
    while (output.size() < limit) { val n = read(buffer, 0, minOf(buffer.size, limit - output.size())); if (n < 0) break; output.write(buffer, 0, n) }
    return output.toByteArray()
}
fun bytes(value: Long) = when { value < 1024 -> "$value B"; value < 1024 * 1024 -> "%.1f KiB".format(value / 1024.0); else -> "%.1f MiB".format(value / 1048576.0) }

fun fileEdit(sha: String, branch: String, text: String, message: String): JSONObject {
    require(validSha(sha) && validBranch(branch) && message.isNotBlank() && text.toByteArray().size <= 1_048_576) { "Refresh the file and choose a branch, commit message, and text up to 1 MiB." }
    return json("sha" to sha, "branch" to branch, "content" to Base64.getEncoder().encodeToString(text.toByteArray()), "message" to message.trim())
}
fun mergeBody(sha: String, method: String): JSONObject { require(validSha(sha) && method in listOf("merge", "squash", "rebase")); return json("sha" to sha, "merge_method" to method) }
fun releaseEdit(name: String, notes: String, prerelease: Boolean) = json("name" to name, "body" to notes, "prerelease" to prerelease)

data class OAuthAttempt(val state: String, val verifier: String) {
    fun challenge(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
    fun authorize(client: String): URI {
        require(client.isNotBlank() && state.isNotBlank() && verifier.isNotBlank())
        val params = mapOf("client_id" to client, "redirect_uri" to CALLBACK, "scope" to "repo notifications", "state" to state, "code_challenge" to challenge(), "code_challenge_method" to "S256", "prompt" to "select_account")
        return URI("https://github.com/login/oauth/authorize?" + params.entries.joinToString("&") { "${encode(it.key)}=${encode(it.value)}" })
    }
    fun code(raw: String): String {
        val uri = URI(raw)
        require(uri.scheme == "app.forge.github" && uri.host == "oauth" && uri.path == "/callback" && uri.userInfo == null && uri.port == -1 && uri.fragment == null) { "Could not verify this sign-in callback." }
        val query = uri.rawQuery.orEmpty().split('&').map { part -> part.split('=', limit = 2).let { URLDecoder.decode(it[0], "UTF-8") to URLDecoder.decode(it.getOrElse(1) { "" }, "UTF-8") } }
        require(query.count { it.first == "state" } == 1 && query.first { it.first == "state" }.second == state) { "Sign-in state did not match. Please start again." }
        require(query.none { it.first == "error" }) { "GitHub sign-in was cancelled or declined." }
        require(query.count { it.first == "code" } == 1) { "Missing sign-in code." }
        val code = query.first { it.first == "code" }.second
        require(Regex("[A-Za-z0-9_-]{1,512}").matches(code)) { "Invalid sign-in code." }; return code
    }
    companion object {
        const val CALLBACK = "app.forge.github://oauth/callback"
        fun create(): OAuthAttempt {
            fun random() = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
            return OAuthAttempt(random(), random())
        }
    }
}

data class DiffLine(val text: String, val old: Int?, val new: Int?, val side: String?) { val number: Int? get() = if (side == "LEFT") old else new }
fun diffLines(patch: String): List<DiffLine> {
    var old = 0; var new = 0; var hunk = false
    val header = Regex("^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@.*")
    return patch.lines().map { text ->
        val match = header.matchEntire(text)
        when {
            match != null -> { old = match.groupValues[1].toInt(); new = match.groupValues[2].toInt(); hunk = true; DiffLine(text, null, null, null) }
            !hunk || text.startsWith('\\') || text.isEmpty() -> DiffLine(text, null, null, null)
            text.startsWith('-') -> DiffLine(text, old++, null, "LEFT")
            text.startsWith('+') -> DiffLine(text, null, new++, "RIGHT")
            text.startsWith(' ') -> DiffLine(text, old++, new++, "RIGHT")
            else -> DiffLine(text, null, null, null)
        }
    }
}

fun route(raw: String): Page? = runCatching {
    val uri = URI(raw)
    if (uri.scheme != "https" || uri.userInfo != null || uri.port !in listOf(-1, 443) || uri.host !in listOf("github.com", "www.github.com", "api.github.com")) return null
    var parts = uri.path.trim('/').split('/').filter { it.isNotEmpty() }
    if (uri.host == "api.github.com") { if (parts.firstOrNull() != "repos") return null; parts = parts.drop(1) }
    if (parts.isEmpty()) return Page("home", "Home")
    if (parts.size == 1 && validLogin(parts[0])) {
        val tab = uri.rawQuery.orEmpty().split('&').firstOrNull { it.startsWith("tab=") }?.substringAfter('=')
        return when (tab) {
            "followers", "following" -> Page("people", tab.replaceFirstChar { it.uppercase() }, id = parts[0], arg = tab)
            "repositories" -> Page("repos", "Repositories", id = parts[0], arg = "user")
            "stars" -> Page("repos", "Starred", id = parts[0], arg = "stars")
            else -> Page("profile", parts[0], id = parts[0])
        }
    }
    val repo = repository(parts.take(2).joinToString("/"))
    if (parts.size == 2) return Page("repo", parts[1], repo)
    when (parts[2]) {
        "issues", "pull", "pulls", "discussions" -> {
            val kind = when (parts[2]) { "issues" -> "issue"; "discussions" -> "discussion"; else -> "pull" }
            if (parts.size >= 4 && parts[3].toLongOrNull() != null) Page(kind, "#${parts[3]}", repo, positiveID(parts[3])) else Page("conversations", parts[2].replaceFirstChar { it.uppercase() }, repo, arg = kind)
        }
        "actions" -> if (parts.size >= 5 && parts[3] == "runs") Page("run", "Workflow run", repo, positiveID(parts[4])) else Page("actions", "Actions", repo)
        "releases" -> if (parts.getOrNull(3) == "tag") Page("releaseTag", "Release", repo, arg = parts.drop(4).joinToString("/")) else Page("releases", "Releases", repo)
        "blob", "tree" -> Page("codeLink", "Code", repo, id = parts[2], arg = parts.drop(3).joinToString("/"))
        else -> null
    }
}.getOrNull()
