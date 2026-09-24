package app.forge.github

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.Base64

data class GitTreeEntry(val path: String, val mode: String, val type: String, val sha: String, val size: Int? = null) {
    override fun equals(other: Any?) = other is GitTreeEntry && path == other.path && mode == other.mode && type == other.type && sha == other.sha
    override fun hashCode() = listOf(path, mode, type, sha).hashCode()
}

data class HistoryResolution(val choice: String, val text: String = "")
class HistoryConflict(val path: String, val before: GitTreeEntry?, val requested: GitTreeEntry?, val current: GitTreeEntry?, val baseText: String?, val requestedText: String?, val currentText: String?) : Exception("Review conflicting changes in $path. No branch was changed. Choose or edit the final file, then confirm again.") {
    val key = (listOf(path) + listOf(before, requested, current).map { it?.let { "${it.mode}:${it.type}:${it.sha}" } ?: "absent" }).joinToString("\u0000")
    val canEdit get() = baseText != null && requestedText != null && currentText != null && before?.mode == requested?.mode && requested?.mode == current?.mode
}

object GitHistory {
    // The API caller resolves text conflicts first; protect all unresolved tree changes here.
    fun apply(before: Map<String, GitTreeEntry>, after: Map<String, GitTreeEntry>, current: Map<String, GitTreeEntry>): Map<String, GitTreeEntry> {
        val result = current.toMutableMap()
        (before.keys + after.keys).filter { before[it] != after[it] }.forEach { path ->
            if (current[path] == after[path]) return@forEach
            require(current[path] == before[path]) { "Conflicting changes in $path. No branch was changed. Resolve this with desktop Git." }
            after[path]?.let { result[path] = it } ?: result.remove(path)
        }
        result.keys.forEach { path ->
            var parent = path.substringBeforeLast('/', "")
            while (parent.isNotEmpty()) { require(parent !in result) { "A file/directory conflict needs desktop Git. No branch was changed." }; parent = parent.substringBeforeLast('/', "") }
        }
        return result
    }
    fun mergeText(base: String, current: String, changed: String): String? {
        if (base == current) return changed
        if (base == changed || current == changed) return current
        val original = base.split('\n')
        data class Edit(val start: Int, val end: Int, val lines: List<String>)
        // ponytail: merge one changed span per side; overlapping spans go to the native conflict editor.
        fun edit(text: String): Edit {
            val lines = text.split('\n'); var start = 0
            while (start < minOf(original.size, lines.size) && original[start] == lines[start]) start++
            var end = original.size; var tail = lines.size
            while (end > start && tail > start && original[end - 1] == lines[tail - 1]) { end--; tail-- }
            return Edit(start, end, lines.subList(start, tail))
        }
        val a = edit(current); val b = edit(changed)
        if ((a.start < b.end && b.start < a.end) || (a.start == a.end && a.start in b.start..b.end) || (b.start == b.end && b.start in a.start..a.end)) return null
        val result = original.toMutableList()
        listOf(a, b).sortedByDescending { it.start }.forEach { result.subList(it.start, it.end).clear(); result.addAll(it.start, it.lines) }
        return result.joinToString("\n")
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

suspend fun GitHub.changeHistory(repo: String, branch: String, expected: String, selected: String, remove: Boolean, resolutions: Map<String, HistoryResolution> = emptyMap(), saveRecovery: (suspend (JSONObject) -> Unit)? = null): String {
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
        val entries = result.rows("tree").filter { it.s("type") != "tree" }.associate { row -> row.s("path") to GitTreeEntry(row.s("path"), row.s("mode"), row.s("type"), row.s("sha"), if (row.has("size")) row.getInt("size") else null) }
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
            val next = tree(item.o("tree").s("sha")); rebuilt = mergeHistory(path, previous, next, rebuilt, resolutions)
            require(plan.sumOf { it.second.size } + rebuilt.size <= 250_000) { "This rewrite is too large for mobile editing. Use desktop Git." }
            plan += item to rebuilt; previous = next
        }
    } else {
        require(obj("$path/compare/$selected...$expected").s("status") in listOf("ahead", "identical")) { "The selected commit is outside this branch." }
        val head = commit(expected); val current = tree(head.o("tree").s("sha"))
        val result = mergeHistory(path, after, before, current, resolutions)
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

suspend fun GitHub.restoreHistory(item: JSONObject, expected: String, reapply: Boolean, resolutions: Map<String, HistoryResolution> = emptyMap()) {
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
            return data.rows("tree").filter { it.s("type") != "tree" }.associate { it.s("path") to GitTreeEntry(it.s("path"), it.s("mode"), it.s("type"), it.s("sha"), if (it.has("size")) it.getInt("size") else null) }
        }
        val entries = mergeHistory(path, tree(parent), tree(chosen), tree(head), resolutions)
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


private suspend fun GitHub.mergeHistory(path: String, before: Map<String, GitTreeEntry>, after: Map<String, GitTreeEntry>, current: Map<String, GitTreeEntry>, resolutions: Map<String, HistoryResolution>): Map<String, GitTreeEntry> {
    val expected = before.toMutableMap(); val desired = after.toMutableMap()
    for (file in (before.keys + after.keys).sorted().filter { before[it] != after[it] && current[it] != before[it] && current[it] != after[it] }) {
        suspend fun text(entry: GitTreeEntry?): String? {
            if (entry == null || entry.type != "blob" || entry.mode !in listOf("100644", "100755") || entry.size == null || entry.size !in 0..1_048_576) return null
            require(validSha(entry.sha)) { "Invalid conflict file revision." }
            val blob = obj("$path/git/blobs/${entry.sha}")
            require(blob.s("encoding") == "base64" && blob.optInt("size", -1) == entry.size) { "Incomplete conflict file. No branch was changed." }
            val bytes = Base64.getMimeDecoder().decode(blob.getString("content"))
            require(bytes.size == entry.size) { "Incomplete conflict file. No branch was changed." }
            if (bytes.contains(0)) return null
            return runCatching { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString() }.getOrNull()
        }
        val conflict = HistoryConflict(file, before[file], after[file], current[file], text(before[file]), text(after[file]), text(current[file]))
        val resolution = resolutions[conflict.key] ?: if (conflict.canEdit) GitHistory.mergeText(conflict.baseText!!, conflict.currentText!!, conflict.requestedText!!)?.let { HistoryResolution("edit", it) } else null
        if (resolution == null) throw conflict
        current[file]?.let { expected[file] = it } ?: expected.remove(file)
        val replacement = when (resolution.choice) {
            "current" -> current[file]
            "requested" -> after[file]
            "edit" -> {
                require(conflict.canEdit && resolution.text.toByteArray().size <= 1_048_576 && '\u0000' !in resolution.text) { "Choose a file version or enter UTF-8 text under 1 MiB." }
                val entry = requireNotNull(after[file]); val bytes = resolution.text.toByteArray()
                val blob = change("$path/git/blobs", body = json("content" to Base64.getEncoder().encodeToString(bytes), "encoding" to "base64"))
                require(validSha(blob.s("sha"))) { "GitHub did not confirm the merged file." }
                GitTreeEntry(file, entry.mode, "blob", blob.s("sha"), bytes.size)
            }
            else -> error("Choose a valid conflict resolution.")
        }
        replacement?.let { desired[file] = it } ?: desired.remove(file)
    }
    return GitHistory.apply(expected, desired, current)
}
