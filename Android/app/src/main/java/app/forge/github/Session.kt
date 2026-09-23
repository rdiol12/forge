package app.forge.github

import android.app.Application
import android.content.Context
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// Tokens and pending PKCE verifiers are encrypted with a non-exportable device key.
class Vault(context: Context) {
    private val prefs = context.getSharedPreferences("credentials", Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("forge.session", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("forge.session", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun read(name: String): String {
        val saved = prefs.getString(name, null) ?: return ""
        return try {
            val bytes = Base64.getDecoder().decode(saved)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
        } catch (_: Exception) { prefs.edit().remove(name).apply(); "" }
    }
    fun save(name: String, value: String) {
        if (value.isEmpty()) { prefs.edit().remove(name).commit(); return }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
        check(prefs.edit().putString(name, Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(value.toByteArray()))).commit()) { "Could not save sign-in securely." }
    }
}

data class Page(val kind: String, val title: String, val repo: String = "", val id: String = "", val arg: String = "", val sha: String = "", val branch: String = "")

class ForgeState(application: Application) : AndroidViewModel(application) {
    private val vault = Vault(application)
    val prefs = application.getSharedPreferences("forge", Context.MODE_PRIVATE)
    private var token by mutableStateOf(vault.read("token"))
    val connected get() = token.isNotBlank()
    val api get() = GitHub(token)
    var account by mutableStateOf(if (connected) prefs.getString("account", "").orEmpty() else "")
        private set
    var generation by mutableIntStateOf(0)
        private set
    var refresh by mutableIntStateOf(0)
    var tab by mutableIntStateOf(0)
    var notice by mutableStateOf<String?>(null)
    var signingIn by mutableStateOf(false)
    var showCopilot by mutableStateOf(prefs.getBoolean("copilot", true))
    val stack = mutableStateListOf<Page>()
    val favorites = mutableStateListOf<String>().apply { addAll(runCatching { JSONArray(prefs.getString("favorites", "[]")).let { a -> (0 until a.length()).map { repository(a.getString(it)) } } }.getOrDefault(emptyList())) }
    val downloads = Downloads(application)

    fun open(page: Page) { stack.add(page) }
    fun back() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    fun chooseTab(value: Int) { tab = value; stack.clear() }
    fun favorite(repo: String) {
        val valid = repository(repo)
        if (favorites.contains(valid)) favorites.remove(valid) else favorites.add(valid)
        prefs.edit().putString("favorites", JSONArray(favorites.toList()).toString()).apply()
    }
    fun task(block: suspend () -> Unit) = viewModelScope.launch {
        try { block() } catch (e: CancellationException) { throw e } catch (e: Exception) { notice = e.message ?: "Something went wrong. Please retry." }
    }
    suspend fun connect(value: String) {
        require(value.trim().isNotEmpty() && !value.any { it == '\n' || it == '\r' }) { "Enter a GitHub access token." }
        val candidate = value.trim(); val login = GitHub(candidate).obj("/user").getString("login")
        downloads.cancelAll(); vault.save("token", candidate); vault.save("oauth", "")
        token = candidate; account = login; generation++; stack.clear()
        prefs.edit().putString("account", login).apply(); notice = "Connected as $login"
    }
    fun disconnect() {
        downloads.cancelAll(); vault.save("token", ""); vault.save("oauth", "")
        token = ""; account = ""; generation++; stack.clear(); prefs.edit().remove("account").apply()
    }

    suspend fun startLogin(context: Context) {
        signingIn = true
        try {
            val config = authRequest("/oauth/config")
            val client = config.s("clientId")
            require(client.isNotEmpty()) { "GitHub browser sign-in is not configured yet. Use a personal access token below." }
            val attempt = OAuthAttempt.create()
            vault.save("oauth", json("state" to attempt.state, "verifier" to attempt.verifier, "expires" to System.currentTimeMillis() + 600_000).toString())
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, Uri.parse(attempt.authorize(client).toString()))
        } finally { signingIn = false }
    }

    fun callback(uri: String) = task {
        val pending = vault.read("oauth"); vault.save("oauth", "")
        require(pending.isNotEmpty()) { "Sign-in expired. Start again in Settings." }
        val saved = JSONObject(pending)
        require(saved.optLong("expires") > System.currentTimeMillis()) { "Sign-in expired. Start again." }
        val attempt = OAuthAttempt(saved.getString("state"), saved.getString("verifier"))
        val code = attempt.code(uri)
        signingIn = true
        try {
            val result = authRequest("/oauth/token", json("code" to code, "codeVerifier" to attempt.verifier))
            require(result.s("token_type").equals("bearer", true)) { "Invalid GitHub token response." }
            connect(result.getString("access_token"))
        } finally { signingIn = false }
    }

    fun link(context: Context, raw: String) {
        val page = route(raw)
        if (page != null) { open(page); return }
        val uri = runCatching { URI(raw) }.getOrNull()
        if (uri?.scheme != "https" || uri.host.isNullOrEmpty() || uri.userInfo != null) { notice = "This link is not supported."; return }
        runCatching { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, Uri.parse(raw)) }
            .onFailure { notice = "Install or enable a browser to open this web page." }
    }

    companion object {
        const val AUTH = "https://forge-github-signin.j239pt2mgegnt9dxw7.chatgpt.site"
        suspend fun authRequest(path: String, body: JSONObject? = null): JSONObject = withContext(Dispatchers.IO) {
            require(path in listOf("/oauth/config", "/oauth/token"))
            val c = URI(AUTH + path).toURL().openConnection() as HttpURLConnection
            try {
                c.instanceFollowRedirects = false; c.useCaches = false; c.connectTimeout = 30_000; c.readTimeout = 30_000
                if (body != null) { c.requestMethod = "POST"; c.doOutput = true; c.setRequestProperty("Content-Type", "application/json"); c.outputStream.use { it.write(body.toString().toByteArray()) } }
                if (c.responseCode == 503) error("GitHub browser sign-in is not configured yet. Connect with a personal access token below.")
                require(c.responseCode == 200) { "GitHub sign-in is unavailable. Please try again or use a token." }
                JSONObject(c.inputStream.use { it.readLimited(16_384).toString(Charsets.UTF_8) })
            } finally { c.disconnect() }
        }
    }
}
