package app.forge.github

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.util.Base64

fun JSONObject.s(key: String): String = optString(key, "").takeUnless { it == "null" } ?: ""
fun JSONObject.o(key: String): JSONObject = optJSONObject(key) ?: JSONObject()
fun JSONObject.rows(key: String): List<JSONObject> = optJSONArray(key)?.objects() ?: emptyList()
fun JSONArray.objects(): List<JSONObject> = (0 until length()).mapNotNull { optJSONObject(it) }
fun json(vararg pairs: Pair<String, Any?>) = JSONObject().apply { pairs.forEach { (k, v) -> put(k, v ?: JSONObject.NULL) } }

fun deploymentReviewBody(environment: Long, approved: Boolean, comment: String): JSONObject {
    require(environment > 0 && comment.isNotBlank()) { "Add a deployment review comment." }
    return json("environment_ids" to JSONArray(listOf(environment)), "state" to if (approved) "approved" else "rejected", "comment" to comment)
}

suspend fun GitHub.reviewDeployment(repo: String, run: String, environment: Long, approved: Boolean, comment: String) {
    val body = deploymentReviewBody(environment, approved, comment)
    val path = "/repos/${repository(repo)}/actions/runs/${positiveID(run)}/pending_deployments"
    cache?.clear()
    val pending = (request(path) as JSONArray).objects()
    require(pending.any { it.o("environment").optLong("id") == environment && it.optBoolean("current_user_can_approve") }) { "This deployment is no longer waiting for you, or you are not an eligible reviewer. Refresh the run." }
    val result = request(path, method = "POST", body = body) as JSONArray
    require(result.length() > 0) { "GitHub did not confirm the deployment review. Refresh before retrying." }
}

suspend fun GitHub.setPullDraft(id: String, draft: Boolean) {
    require(id.isNotBlank()) { "Refresh the pull request first." }
    val mutation = if (draft) "convertPullRequestToDraft" else "markPullRequestReadyForReview"
    val result = gql("mutation(\$id:ID!){result:$mutation(input:{pullRequestId:\$id}){pullRequest{isDraft}}}", json("id" to id)).o("result").o("pullRequest")
    require(result.has("isDraft") && result.getBoolean("isDraft") == draft) { "GitHub did not confirm the PR status. Refresh before retrying." }
}

class GitHub(val token: String, val cache: APIMemoryCache? = null) {
    fun connection(uri: URI, accept: String = "application/vnd.github+json"): HttpURLConnection {
        require(trustedDownload(uri)) { "Unsupported GitHub download location." }
        return (uri.toURL().openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false; useCaches = false; connectTimeout = 30_000; readTimeout = 60_000
            setRequestProperty("Accept", accept); setRequestProperty("User-Agent", "Forge-Android")
            if (uri.host.equals("api.github.com", true)) {
                setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
                if (token.isNotEmpty()) setRequestProperty("Authorization", "Bearer $token")
            }
        }
    }

    suspend fun request(path: String, query: Map<String, String> = emptyMap(), method: String = "GET", body: JSONObject? = null): Any = withContext(Dispatchers.IO) {
        if (method != "GET") require(token.isNotBlank()) { "Connect GitHub in Settings before making changes." }
        var uri = apiUrl(path, query)
        val reading = method == "GET" || (path == "/graphql" && body?.s("query")?.trimStart()?.startsWith("query") == true)
        val key = "$token\n$uri\n$method\n${body ?: ""}"
        val epoch = cache?.epoch ?: 0; val old = if (reading) cache?.value(key) else null
        fun decoded(text: String): Any = if (text.isBlank()) JSONObject() else if (text.trimStart().startsWith("[")) JSONArray(text) else JSONObject(text)
        if (old?.fresh == true) return@withContext decoded(old.bytes.toString(Charsets.UTF_8))
        if (!reading) cache?.clear()
        repeat(6) {
            val c = connection(uri)
            old?.etag?.let { c.setRequestProperty("If-None-Match", it) }
            try {
                c.requestMethod = method
                if (body != null) { c.doOutput = true; c.setRequestProperty("Content-Type", "application/json"); c.outputStream.use { it.write(body.toString().toByteArray()) } }
                val status = c.responseCode
                if (status == 304 && old != null) { cache?.store(key, old.bytes, c.getHeaderField("ETag") ?: old.etag, epoch, c.getHeaderField("Cache-Control") ?: old.control); return@withContext decoded(old.bytes.toString(Charsets.UTF_8)) }
                if (status in listOf(301, 302, 307, 308) && method == "GET") {
                    val next = uri.resolve(c.getHeaderField("Location") ?: error("Missing redirect location."))
                    require(next.host == "api.github.com" && trustedDownload(next)) { "Unexpected API redirect." }; uri = next
                } else {
                    if (status !in 200..299) throw failure(c)
                    val bytes = c.inputStream.use { it.readLimited(16_777_217) }
                    require(bytes.size <= 16_777_216) { "Response is too large; narrow the search." }
                    val result = decoded(bytes.toString(Charsets.UTF_8))
                    if (reading && status == 200 && (result !is JSONObject || !result.has("errors"))) cache?.store(key, bytes, c.getHeaderField("ETag"), epoch, c.getHeaderField("Cache-Control") ?: "")
                    return@withContext result
                }
            } catch (e: java.io.IOException) {
                throw IllegalStateException(if (reading) "Could not reach GitHub. Check your connection and retry." else "Could not confirm the change. Refresh before submitting again; GitHub may have saved it.")
            } finally { c.disconnect(); if (!reading) cache?.clear() }
        }
        error("Too many GitHub redirects.")
    }

    suspend fun obj(path: String, query: Map<String, String> = emptyMap()) = request(path, query) as JSONObject
    suspend fun list(path: String, page: Int = 1, query: Map<String, String> = emptyMap()): List<JSONObject> =
        (request(path, query + mapOf("per_page" to "30", "page" to page.toString())) as JSONArray).objects()
    suspend fun change(path: String, method: String = "POST", body: JSONObject = JSONObject()) = request(path, method = method, body = body) as JSONObject
    suspend fun gql(query: String, variables: JSONObject = JSONObject()): JSONObject {
        val result = change("/graphql", body = json("query" to query, "variables" to variables))
        require(result.rows("errors").isEmpty()) { result.rows("errors").firstOrNull()?.s("message") ?: "GitHub did not return the requested data." }
        return result.getJSONObject("data")
    }

    suspend fun blob(repo: String, sha: String): String {
        require(validSha(sha)); val data = obj("/repos/${repository(repo)}/git/blobs/$sha")
        require(data.optLong("size") <= 1_048_576 && data.s("encoding") == "base64") { "Preview supports UTF-8 files up to 1 MiB. Download this file to open it." }
        val bytes = Base64.getMimeDecoder().decode(data.s("content"))
        require(bytes.size.toLong() == data.optLong("size") && !bytes.contains(0)) { "Binary file. Download it to open it." }
        return Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    }

    suspend fun log(path: String): String = withContext(Dispatchers.IO) {
        var uri = apiUrl(path)
        repeat(6) {
            val c = connection(uri)
            try {
                if (c.responseCode in listOf(301, 302, 303, 307, 308)) {
                    uri = uri.resolve(c.getHeaderField("Location") ?: error("Missing log location."))
                    require(trustedDownload(uri)) { "Unsupported log redirect." }
                } else {
                    if (c.responseCode !in 200..299) throw failure(c)
                    val data = c.inputStream.use { it.readLimited(2_097_153) }
                    return@withContext data.take(2_097_152).toByteArray().toString(Charsets.UTF_8).replace(Regex("\\u001B\\[[0-?]*[ -/]*[@-~]"), "") + if (data.size > 2_097_152) "\nPreview limited to 2 MiB. Download the full log above." else ""
                }
            } finally { c.disconnect() }
        }
        error("Too many log redirects.")
    }

    suspend fun setVisibility(repo: String, expected: String, private: Boolean) {
        cache?.clear()
        val path = "/repos/${repository(repo)}"; val current = obj(path)
        require(current.o("permissions").optBoolean("admin")) { "Repository admin permission is required." }
        require(expected in listOf("public", "private") && current.s("visibility") == expected) { "Visibility changed. Refresh before continuing." }
        val result = change(path, "PATCH", json("private" to private))
        require(result.optBoolean("private") == private) { "GitHub did not confirm the visibility change." }
    }

    suspend fun editIssue(repo: String, id: String, original: JSONObject, title: String, body: String, labels: List<String>?, assignees: List<String>?) {
        cache?.clear()
        require(title.isNotBlank()); val path = "/repos/${repository(repo)}/issues/${positiveID(id)}"
        require(obj(path).s("updated_at") == original.s("updated_at")) { "Issue changed. Refresh to avoid overwriting another edit." }
        val patch = JSONObject()
        if (title != original.s("title")) patch.put("title", title)
        if (body != original.s("body")) patch.put("body", body)
        if (labels != null && labels.toSet() != original.rows("labels").map { it.s("name") }.toSet()) patch.put("labels", JSONArray(labels))
        if (assignees != null && assignees.toSet() != original.rows("assignees").map { it.s("login") }.toSet()) patch.put("assignees", JSONArray(assignees))
        if (patch.length() == 0) return
        val result = change(path, "PATCH", patch)
        if (patch.has("labels")) require(result.rows("labels").map { it.s("name") }.toSet() == labels!!.toSet()) { "GitHub did not apply all labels. Check your permission and refresh." }
        if (patch.has("assignees")) require(result.rows("assignees").map { it.s("login") }.toSet() == assignees!!.toSet()) { "GitHub did not apply all assignees. Check your permission and refresh." }
    }

    companion object {
        fun failure(c: HttpURLConnection): Exception {
            val message = runCatching { JSONObject(c.errorStream?.use { it.readLimited(8192).toString(Charsets.UTF_8) } ?: "{}").s("message") }.getOrDefault("")
            val status = c.responseCode
            return IllegalStateException(when {
                status == 429 || (status == 403 && c.getHeaderField("X-RateLimit-Remaining") == "0") -> "GitHub rate limit reached. Wait before refreshing; signing in increases the limit."
                status == 401 -> "GitHub rejected this token. Reconnect in Settings."
                status == 404 -> "Not found, or your token cannot access this content."
                status == 410 -> "This artifact has expired or was deleted."
                else -> "GitHub HTTP $status: ${message.ifBlank { "Check your connection and repository permissions." }}"
            })
        }
    }
}
