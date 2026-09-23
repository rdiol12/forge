package app.forge.github

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class AppTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun state() = ForgeState(context.applicationContext as Application)
    private fun screenshot(name: String) {
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val folder = File(context.getExternalFilesDir(null), "screenshots").apply { mkdirs() }
        File(folder, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Test fun nativeNavigationAndLightAppearance() {
        val state = state()
        compose.setContent { ForgeTheme(dark = false) { ForgeApp(state) } }
        compose.onNodeWithText("My Work").assertIsDisplayed()
        compose.onNodeWithText("Pull Requests").assertIsDisplayed()
        screenshot("home-light")
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithText("Sign in with GitHub").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Explore").performClick()
        compose.onNodeWithText("Search repositories or enter owner/name").assertIsDisplayed()
        compose.onNodeWithText("Profile").performClick()
        compose.onNodeWithText("Personal access token").assertIsDisplayed()
    }

    @Test fun darkAppearance() {
        val state = state()
        compose.setContent { ForgeTheme(dark = true) { ForgeApp(state) } }
        compose.onNodeWithText("My Work").assertIsDisplayed(); screenshot("home-dark")
    }

    @Test fun codeReaderSearchWrapAndCopy() {
        compose.setContent { ForgeTheme { CodeReader("package app.forge.github\n\n// Readable native code\ndata class Build(val status: String)\nval status = \"success\"", "Build.kt") } }
        compose.waitUntil(10_000) { compose.onAllNodesWithText("5 lines").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Wrap").performClick()
        compose.onNodeWithText("Find in file").performTextInput("success")
        compose.onNodeWithText("1/1 ↓").assertIsDisplayed()
        screenshot("code")
        compose.onNodeWithText("Copy").performClick()
    }

    @Test fun peopleRowsStayNative() {
        val state = state()
        compose.setContent { ForgeTheme { CompositionLocalProvider(LocalForge provides state) { Column {
            PersonRow(json("login" to "octocat", "name" to "The Octocat"))
            PersonRow(json("login" to "github", "name" to "GitHub"))
        } } } }
        compose.onNodeWithText("The Octocat").performClick()
        compose.runOnIdle { assertEquals(Page("profile", "octocat", id = "octocat"), state.stack.last()) }
        screenshot("people")
    }

    @Test fun vaultEncryptsAndPersistsOnDevice() {
        val secret = "local-test-token-only"
        try {
            Vault(context).save("test", secret)
            assertEquals(secret, Vault(context).read("test"))
            assertFalse(context.getSharedPreferences("credentials", 0).getString("test", "")!!.contains(secret))
        } finally { Vault(context).save("test", "") }
    }

    @Test fun editorDraftSurvivesScreenRecreation() {
        val state = state(); val show = mutableStateOf(true); val revision = mutableStateOf("original")
        var submittedRevision = ""
        compose.setContent { ForgeTheme { CompositionLocalProvider(LocalForge provides state) {
            val expectedRevision = revision.value
            if (show.value) EditDialog("New issue", listOf(Field("Title")), dismiss = { show.value = false }) { submittedRevision = expectedRevision }
        } } }
        compose.onNodeWithText("Title").performTextInput("Keep this draft")
        compose.runOnIdle { show.value = false; revision.value = "changed" }; compose.waitForIdle()
        compose.runOnIdle { show.value = true }; compose.waitForIdle()
        compose.onNodeWithText("Keep this draft").assertIsDisplayed()
        compose.onNodeWithText("Save").performClick(); compose.waitForIdle()
        compose.runOnIdle { assertEquals("original", submittedRevision); assertTrue(state.drafts.isEmpty()); show.value = true }
        compose.onNodeWithText("Title").performTextInput("Unsaved change")
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Discard changes?").assertIsDisplayed()
        compose.onNodeWithText("Discard", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertTrue(state.drafts.isEmpty()) }
    }

    @Test fun privateRepositoryWorkflowsReleasesAndPinnedCodeAreReadable() = runBlocking {
        val file = File(context.filesDir, "live-token")
        assumeTrue("CI supplies an ephemeral read token for this check", file.exists())
        val api = GitHub(file.readText().trim())
        val repo = "rdiol12/forge-ios"
        val info = api.obj("/repos/$repo")
        assertTrue(info.optBoolean("private"))
        val branch = info.getString("default_branch")
        val sha = api.obj("/repos/$repo/git/ref/heads/$branch").o("object").getString("sha")
        assertTrue(validSha(sha))
        val readme = api.obj("/repos/$repo/readme", mapOf("ref" to sha))
        assertTrue(api.blob(repo, readme.getString("sha")).contains("Forge"))
        val runs = api.obj("/repos/$repo/actions/runs", mapOf("per_page" to "1", "status" to "success")).rows("workflow_runs")
        assertTrue(runs.isNotEmpty())
        val jobs = api.obj("/repos/$repo/actions/runs/${runs.first().getLong("id")}/jobs").rows("jobs")
        assertTrue(jobs.any { it.rows("steps").isNotEmpty() })
        val releases = api.list("/repos/$repo/releases")
        assertTrue(releases.isNotEmpty())
        val assets = api.list("/repos/$repo/releases/${releases.first().getLong("id")}/assets")
        assertTrue(assets.any { it.s("name").endsWith(".ipa") || it.s("name").endsWith(".apk") })
        assertTrue(assets.all { it.has("download_count") })
        val asset = assets.first { it.s("name").endsWith(".ipa") || it.s("name").endsWith(".apk") }
        val artifacts = api.obj("/repos/$repo/actions/artifacts", mapOf("per_page" to "30")).rows("artifacts")
        val artifact = artifacts.first { !it.optBoolean("expired") && it.s("name").startsWith("Forge-unsigned") }
        val downloads = withContext(Dispatchers.Main) { Downloads(context) }
        for (spec in listOf(
            DownloadSpec("/repos/$repo/releases/assets/${asset.getLong("id")}", asset.getString("name"), "application/octet-stream"),
            DownloadSpec("/repos/$repo/actions/artifacts/${artifact.getLong("id")}/zip", "workflow-artifact.zip", auth = true)
        )) {
            val entry = withContext(Dispatchers.Main) { downloads.start(api, spec); downloads.entries.first() }
            var complete = false
            for (attempt in 1..90) {
                delay(1000)
                val active = withContext(Dispatchers.Main) { downloads.refresh(); entry.active }
                if (!active) { complete = true; break }
            }
            assertTrue("Download timed out", complete)
            val downloaded = withContext(Dispatchers.Main) { downloads.file(entry) }
            assertTrue(downloaded.length() > 0)
            downloaded.inputStream().use { assertEquals('P'.code, it.read()); assertEquals('K'.code, it.read()) }
            withContext(Dispatchers.Main) {
                // A transfer may finish while another screen still holds its last in-progress state.
                entry.active = true; entry.status = "Downloading…"
                downloads.cancelAll()
                assertEquals("Saved", entry.status)
                assertTrue(downloads.file(entry).isFile)
            }
        }
    }
}
