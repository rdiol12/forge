package app.forge.github

import android.graphics.Canvas
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.runBlocking
import java.io.ByteArrayInputStream
import java.net.URI
import java.net.URLConnection

@Composable fun RichReadme(document: ReadmeDocument) {
    val state = LocalForge.current; val api = state.api
    val dark = MaterialTheme.colorScheme.surface.luminance() < .5f
    var height by remember(document) { mutableIntStateOf(80) }
    val html = remember(document, dark) { document.page(dark) }
    AndroidView(modifier = Modifier.fillMaxWidth().height(height.dp), factory = { context ->
        object : WebView(context) {
            override fun onDraw(canvas: Canvas) {
                super.onDraw(canvas)
                val next = contentHeight.coerceAtLeast(80)
                if (kotlin.math.abs(next - height) > 1) post { height = next }
            }
        }.apply {
            settings.javaScriptEnabled = false; settings.allowFileAccess = false; settings.allowContentAccess = false
            settings.domStorageEnabled = false; settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
            isVerticalScrollBarEnabled = false; setBackgroundColor(android.graphics.Color.TRANSPARENT)
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val url = request.url.toString()
                    if (url.substringBefore('#') == document.base && request.url.fragment != null) return false
                    if (request.isForMainFrame && request.url.scheme == "https") state.link(context, url)
                    return true
                }
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    val uri = runCatching { URI(request.url.toString()) }.getOrNull() ?: return emptyImage()
                    if (uri.scheme == "forge-readme") return runCatching {
                        val path = document.imagePath(uri) ?: error("Invalid image.")
                        val bytes = runBlocking { api.data("/repos/${document.repo}/contents/$path", mapOf("ref" to document.sha)) }
                        WebResourceResponse(URLConnection.guessContentTypeFromName(path) ?: if (path.endsWith(".svg")) "image/svg+xml" else "application/octet-stream", null, ByteArrayInputStream(bytes))
                    }.getOrElse { emptyImage() }
                    return if (uri.scheme == "https" && uri.userInfo == null && uri.port in listOf(-1, 443)) null else emptyImage()
                }
            }
        }
    }, update = { web -> if (web.tag != html) { web.tag = html; web.loadDataWithBaseURL(document.base, html, "text/html", "UTF-8", null) } }, onRelease = { it.stopLoading(); it.destroy() })
}

private fun emptyImage() = WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))

@Composable fun ReadmeCard(repo: String, branch: String, sha: String, canEdit: Boolean = true) {
    val state = LocalForge.current
    Group {
        Loaded("$repo:$sha", load = { state.api.readme(repo, sha) }) { (file, document) ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                if (canEdit && state.connected) TextButton(onClick = { state.open(Page("file", file.s("name"), repo, id = "edit", arg = file.s("path"), sha = file.s("sha"), branch = branch)) }) { Text("Edit") }
                Text(file.s("name"), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(16.dp))
            }
            HorizontalDivider(); key(sha) { RichReadme(document) }
        }
    }
}
