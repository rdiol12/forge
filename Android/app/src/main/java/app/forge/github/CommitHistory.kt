package app.forge.github

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.Base64

data class GitTreeEntry(val path: String, val mode: String, val type: String, val sha: String)

object GitHistory {
    // ponytail: overlapping whole-file edits need desktop Git's three-way merge.
    fun apply(before: Map<String, GitTreeEntry>, after: Map<String, GitTreeEntry>, current: Map<String, GitTreeEntry>): Map<String, GitTreeEntry> {
        val result = current.toMutableMap()
        (before.keys + after.keys).filter { before[it] != after[it] }.forEach { path ->
            require(current[path] == before[path]) { "Conflicting changes in $path. No branch was changed. Resolve this with desktop Git." }
            after[path]?.let { result[path] = it } ?: result.remove(path)
        }
        result.keys.forEach { path ->
            var parent = path.substringBeforeLast('/', "")
            while (parent.isNotEmpty()) { require(parent !in result) { "A file/directory conflict needs desktop Git. No branch was changed." }; parent = parent.substringBeforeLast('/', "") }
        }
        return result
    }
    fun packet(text: String): ByteArray { val data = text.toByteArray(); return "%04x".format(data.size + 4).toByteArray() + data }
    fun pushPacket(branch: String, old: String, new: String): ByteArray {
        require(validBranch(branch) && branch.toByteArray().size <= 1024 && validSha(old) && validSha(new)) { "Invalid branch update." }
        val pack = "PACK".toByteArray() + byteArrayOf(0, 0, 0, 2, 0, 0, 0, 0)
        return packet("$old $new refs/heads/$branch\u0000report-status\n") + "0000".toByteArray() + pack + MessageDigest.getInstance("SHA-1").digest(pack)
    }
    fun validateReport(data: ByteArray, branch: String) {
        var offset = 0; val lines = mutableListOf<String>()
        while (offset + 4 <= data.size) {
            val length = data.copyOfRange(offset, offset + 4).toString(Charsets.UTF_8).toIntOrNull(16) ?: error("Invalid Git response. Refresh the branch.")
            offset += 4; if (length == 0) break
            require(length >= 4 && offset + length - 4 <= data.size) { "Incomplete Git response. Refresh the branch." }
            lines += data.copyOfRange(offset, offset + length - 4).toString(Charsets.UTF_8).trimEnd('\n'); offset += length - 4
        }
        require("unpack ok" in lines && "ok refs/heads/$branch" in lines) { lines.firstOrNull { it.startsWith("ng ") } ?: "GitHub did not confirm the branch update. Check repository rules." }
    }
}

suspend fun GitHub.changeHistory(repo: String, branch: String, expected: String, selected: String, remove: Boolean, saveRecovery: (suspend (JSONObject) -> Unit)? = null): String {
    require(token.isNotBlank() && validBranch(branch) && validSha(expected) && validSha(selected)) { "Connect GitHub and select a valid branch and commit." }
    cache?.clear(); val path = "/repos/${repository(repo)}"
    require(obj("$path/git/ref/heads/$branch").o("object").s("sha") == expected) { "This branch changed. Refresh the commit list before trying again." }
    require(obj(path).o("permissions").optBoolean("push")) { "Repository write access is required." }
    suspend fun commit(sha: String) = obj("$path/git/commits/$sha")
    val chosen = commit(selected)
    require(chosen.rows("parents").size == 1) { "Root and merge commits need desktop Git. No branch was changed." }
    val trees = mutableMapOf<String, Map<String, GitTreeEntry>>()
    suspend fun tree(sha: String): Map<String, GitTreeEntry> {
        trees[sha]?.let { return it }
        val result = obj("$path/git/trees/$sha", mapOf("recursive" to "1"))
        require(!result.optBoolean("truncated")) { "This repository tree is too large for safe mobile editing. Use desktop Git." }
        val entries = result.rows("tree").filter { it.s("type") != "tree" }.associate { row -> row.s("path") to GitTreeEntry(row.s("path"), row.s("mode"), row.s("type"), row.s("sha")) }
        require(trees.values.sumOf { it.size } + entries.size <= 250_000) { "This history is too large for mobile editing. Use desktop Git." }
        trees[sha] = entries; return entries
    }
    val parent = commit(chosen.rows("parents").first().s("sha"))
    val before = tree(parent.o("tree").s("sha")); val after = tree(chosen.o("tree").s("sha"))
    val plan = mutableListOf<Pair<JSONObject?, Map<String, GitTreeEntry>>>()
    var newHead = parent.s("sha")
    if (remove) {
        val later = mutableListOf<JSONObject>(); var cursor = expected
        // ponytail: rewriting more than 200 later commits needs desktop Git.
        while (cursor != selected) {
            require(later.size < 200) { "More than 200 later commits. Use desktop Git to rewrite this history." }
            val item = commit(cursor)
            require(item.rows("parents").size == 1) { "This rewrite crosses a merge or the commit is outside this branch. Use desktop Git." }
            later += item; cursor = item.rows("parents").first().s("sha")
        }
        var rebuilt = before; var previous = after
        later.asReversed().forEach { item ->
            val next = tree(item.o("tree").s("sha")); rebuilt = GitHistory.apply(previous, next, rebuilt)
            require(plan.sumOf { it.second.size } + rebuilt.size <= 250_000) { "This rewrite is too large for mobile editing. Use desktop Git." }
            plan += item to rebuilt; previous = next
        }
    } else {
        require(obj("$path/compare/$selected...$expected").s("status") in listOf("ahead", "identical")) { "The selected commit is outside this branch." }
        val head = commit(expected); val current = tree(head.o("tree").s("sha"))
        val result = GitHistory.apply(after, before, current)
        require(result != current) { "This commit has no file changes to undo." }
        plan += null to result; newHead = expected
    }
    for ((original, entries) in plan) {
        val list = JSONArray(entries.values.sortedBy { it.path }.map { json("path" to it.path, "mode" to it.mode, "type" to it.type, "sha" to it.sha) })
        val newTree = change("$path/git/trees", body = json("tree" to list)).getString("sha")
        val fields = json("tree" to newTree, "parents" to JSONArray(listOf(newHead)), "message" to (original?.s("message") ?: "Revert \"${chosen.s("message").lineSequence().first()}\"\n\nThis reverts commit $selected."))
        original?.o("author")?.let { fields.put("author", it) }
        newHead = change("$path/git/commits", body = fields).getString("sha")
    }
    if (remove) {
        require(saveRecovery != null) { "Save a recovery record before removing history." }
        saveRecovery(json("id" to java.util.UUID.randomUUID().toString(), "repository" to repo, "branch" to branch, "selected" to selected, "oldHead" to expected, "newHead" to newHead, "message" to chosen.s("message"), "created" to java.time.Instant.now().toString()))
    }
    pushBranch(repo, branch, expected, newHead); cache?.clear(); return newHead
}

fun validRecovery(item: JSONObject): Boolean = runCatching { repository(item.s("repository")); require(validBranch(item.s("branch"))); require(listOf("selected", "oldHead", "newHead").all { validSha(item.s(it)) }); true }.getOrDefault(false)

suspend fun GitHub.restoreHistory(item: JSONObject, expected: String, reapply: Boolean) {
    require(validRecovery(item) && validSha(expected)) { "Invalid recovery record." }
    cache?.clear(); val repo = item.s("repository"); val branch = item.s("branch"); val path = "/repos/$repo"
    require(obj("$path/git/ref/heads/$branch").o("object").s("sha") == expected) { "The branch changed. Refresh before restoring." }
    var destination = item.s("oldHead")
    if (reapply) {
        require(obj("$path/compare/${item.s("selected")}...$expected").s("status") !in listOf("ahead", "identical")) { "This commit is already in the branch history." }
        val chosen = obj("$path/git/commits/${item.s("selected")}")
        require(chosen.rows("parents").size == 1) { "This commit needs desktop Git to reapply." }
        val parent = obj("$path/git/commits/${chosen.rows("parents").first().s("sha")}"); val head = obj("$path/git/commits/$expected")
        suspend fun tree(commit: JSONObject): Map<String, GitTreeEntry> {
            val data = obj("$path/git/trees/${commit.o("tree").s("sha")}", mapOf("recursive" to "1"))
            require(!data.optBoolean("truncated")) { "This repository tree is too large for mobile editing." }
            return data.rows("tree").filter { it.s("type") != "tree" }.associate { it.s("path") to GitTreeEntry(it.s("path"), it.s("mode"), it.s("type"), it.s("sha")) }
        }
        val entries = GitHistory.apply(tree(parent), tree(chosen), tree(head))
        val newTree = change("$path/git/trees", body = json("tree" to JSONArray(entries.values.map { json("path" to it.path, "mode" to it.mode, "type" to it.type, "sha" to it.sha) }))).getString("sha")
        destination = change("$path/git/commits", body = json("tree" to newTree, "parents" to JSONArray(listOf(expected)), "message" to (chosen.s("message") + "\n\nReapplied from ${chosen.s("sha")} by Forge."), "author" to chosen.o("author"))).getString("sha")
    } else require(expected == item.s("newHead")) { "The branch changed since removal. Use Reapply commit to preserve newer work, or recover the saved SHA with desktop Git." }
    pushBranch(repo, branch, expected, destination); cache?.clear()
}

private suspend fun GitHub.pushBranch(repo: String, branch: String, old: String, new: String) {
    try {
        withContext(Dispatchers.IO) {
            val c = URI("https", "github.com", "/${repository(repo)}.git/git-receive-pack", null).toURL().openConnection() as HttpURLConnection
            try {
                c.requestMethod = "POST"; c.instanceFollowRedirects = false; c.connectTimeout = 30_000; c.readTimeout = 60_000; c.doOutput = true
                c.setRequestProperty("Authorization", "Basic " + Base64.getEncoder().encodeToString("x-access-token:$token".toByteArray()))
                c.setRequestProperty("Content-Type", "application/x-git-receive-pack-request"); c.setRequestProperty("Accept", "application/x-git-receive-pack-result")
                c.outputStream.use { it.write(GitHistory.pushPacket(branch, old, new)) }
                require(c.responseCode == 200) { "GitHub rejected the branch update (HTTP ${c.responseCode}). Check token permissions and repository rules." }
                GitHistory.validateReport(c.inputStream.use { it.readLimited(1_048_576) }, branch)
            } finally { c.disconnect() }
        }
    } catch (e: Exception) {
        cache?.clear()
        if (runCatching { obj("/repos/${repository(repo)}/git/ref/heads/$branch").o("object").s("sha") }.getOrNull() == new) return
        error("${e.message} Refresh the branch before retrying. Git rejects the update if its previous SHA changed.")
    }
}
