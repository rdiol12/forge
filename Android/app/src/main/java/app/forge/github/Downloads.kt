package app.forge.github

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import androidx.compose.runtime.*
import androidx.core.content.FileProvider
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.UUID

data class DownloadSpec(val path: String, val name: String, val accept: String = "application/vnd.github+json", val auth: Boolean = false) {
    fun json() = json("path" to path, "name" to name, "accept" to accept, "auth" to auth)
    companion object { fun from(j: JSONObject) = DownloadSpec(j.getString("path"), safeName(j.getString("name")), j.getString("accept"), j.optBoolean("auth")) }
}

class DownloadEntry(val key: String, val spec: DownloadSpec) {
    var systemID by mutableLongStateOf(0)
    var file by mutableStateOf("")
    var status by mutableStateOf("Preparing…")
    var progress by mutableStateOf<Float?>(null)
    var active by mutableStateOf(true)
}

class Downloads(private val context: Context) {
    private val manager = context.getSystemService(DownloadManager::class.java)
    private val prefs = context.getSharedPreferences("downloads", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val preparing = mutableMapOf<String, Job>()
    val entries = mutableStateListOf<DownloadEntry>()
    private val folder = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: File(context.filesDir, "downloads").also { it.mkdirs() }, "").also { it.mkdirs() }

    init {
        runCatching { JSONArray(prefs.getString("entries", "[]")).objects().forEach { j ->
            val entry = DownloadEntry(j.getString("key"), DownloadSpec.from(j.getJSONObject("spec")))
            entry.systemID = j.optLong("systemID"); entry.file = j.s("file"); entry.active = j.optBoolean("active")
            entry.status = j.s("status")
            if (entry.active && entry.systemID == 0L) { entry.active = false; entry.status = "Interrupted. Try again." }
            entries.add(entry)
        } }
        refresh()
    }
    private fun save() { prefs.edit().putString("entries", JSONArray(entries.map { e -> json("key" to e.key, "spec" to e.spec.json(), "systemID" to e.systemID, "file" to e.file, "active" to e.active, "status" to e.status) }).toString()).apply() }

    fun start(api: GitHub, spec: DownloadSpec) {
        if (spec.auth && api.token.isBlank()) throw IllegalArgumentException("Connect GitHub to download Actions artifacts.")
        apiUrl(spec.path)
        val entry = DownloadEntry(UUID.randomUUID().toString(), spec.copy(name = safeName(spec.name)))
        entries.add(0, entry); save()
        preparing[entry.key] = scope.launch {
            var completedFile: File? = null
            try {
                val target = File(folder, "${entry.key}-${entry.spec.name}")
                val storage = withContext(Dispatchers.IO) {
                    var uri = apiUrl(spec.path)
                    var result: URI? = null
                    var complete = false
                    repeat(6) {
                        if (!complete) {
                            ensureActive()
                            val c = api.connection(uri, spec.accept)
                            try {
                                val status = c.responseCode
                                if (status in listOf(301, 302, 303, 307, 308)) {
                                    val next = uri.resolve(c.getHeaderField("Location") ?: error("Missing download location."))
                                    require(trustedDownload(next)) { "Unsupported download redirect." }
                                    if (backgroundLocation(next)) { result = next; complete = true } else uri = next
                                } else {
                                    if (status !in 200..299) throw GitHub.failure(c)
                                    // Direct API blobs stay in-process so the system never receives the API token.
                                    val temp = File(folder, "${entry.key}.part")
                                    try {
                                        c.inputStream.use { input -> temp.outputStream().use { output ->
                                            val buffer = ByteArray(64 * 1024)
                                            while (true) { ensureActive(); val count = input.read(buffer); if (count < 0) break; output.write(buffer, 0, count) }
                                        } }
                                        ensureActive(); check(temp.renameTo(target)) { "Could not save the downloaded file." }
                                        completedFile = target; complete = true
                                    } finally { temp.delete() }
                                }
                            } finally { c.disconnect() }
                        }
                    }
                    require(complete) { "Too many download redirects." }; result
                }
                ensureActive()
                if (storage != null) {
                    // DownloadManager follows redirects automatically. Pass NO Authorization or Cookie headers.
                    entry.systemID = manager.enqueue(DownloadManager.Request(Uri.parse(storage.toString()))
                        .setTitle(entry.spec.name).setDescription("Forge download")
                        .setDestinationUri(Uri.fromFile(target))
                        .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED))
                    entry.file = target.name; entry.status = "Downloading…"
                } else { entry.file = target.name; entry.active = false; entry.status = "Saved" }
                save()
            } catch (e: CancellationException) {
                completedFile?.delete(); entry.active = false; entry.status = "Cancelled"; save(); throw e
            } catch (e: Exception) { entry.active = false; entry.status = e.message ?: "Download failed. Try again."; save() }
            finally { preparing.remove(entry.key) }
        }
    }

    fun refresh() {
        entries.filter { it.systemID > 0 && it.active }.forEach { e ->
            manager.query(DownloadManager.Query().setFilterById(e.systemID))?.use { c ->
                if (!c.moveToFirst()) { e.active = false; e.status = "Interrupted. Try again." }
                else {
                    val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                    val total = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                    val done = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                    e.progress = if (total > 0) (done.toFloat() / total).coerceIn(0f, 1f) else null
                    when (status) {
                        DownloadManager.STATUS_SUCCESSFUL -> { e.active = false; e.status = "Saved" }
                        DownloadManager.STATUS_FAILED -> { e.active = false; e.status = "Download failed (${c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))}). Try again." }
                        DownloadManager.STATUS_PAUSED -> e.status = "Waiting for network…"
                        else -> e.status = "Downloading…"
                    }
                }
            }
        }; save()
    }
    fun cancel(entry: DownloadEntry) {
        preparing[entry.key]?.cancel()
        if (entry.systemID > 0) manager.remove(entry.systemID)
        entry.active = false; entry.status = "Cancelled"; entry.file = ""; save()
    }
    fun cancelAll() { entries.filter { it.active }.forEach(::cancel) }
    fun retry(api: GitHub, entry: DownloadEntry) { cancel(entry); entries.remove(entry); start(api, entry.spec) }
    fun file(entry: DownloadEntry): File {
        require(entry.status == "Saved" && entry.file.isNotBlank()) { "Download this file first." }
        val file = File(folder, entry.file).canonicalFile
        require(file.parentFile == folder.canonicalFile && file.isFile) { "The saved file is no longer available. Try downloading again." }
        return file
    }
    fun share(entry: DownloadEntry) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file(entry))
        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("application/octet-stream").putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), "Share ${entry.spec.name}").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
