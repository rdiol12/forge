package app.forge.github

import android.app.Application
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.SoftwareKeyboardController
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NavigationTest {
    @get:Rule val compose = createComposeRule()

    @Test fun failedDownloadCanBeRemovedWithoutALocalFile() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val state = ForgeState(context.applicationContext as Application)
        val entry = DownloadEntry(java.util.UUID.randomUUID().toString(), DownloadSpec("/repos/owner/repo/releases/assets/1", "failed-download-test.zip")).apply { active = false; status = "Download failed. Try again." }
        state.downloads.entries.add(0, entry); state.open(Page("downloads", "Downloads"))
        try {
            compose.setContent { ForgeTheme { ForgeApp(state) } }
            compose.onNodeWithText("Remove failed download").performClick()
            compose.onNodeWithText("Delete", substring = false).performClick()
            compose.waitUntil(10_000) { entry !in state.downloads.entries }
            compose.onNodeWithText("failed-download-test.zip").assertDoesNotExist()
            assertTrue(Downloads(context).entries.none { it.key == entry.key })
        } finally { if (entry in state.downloads.entries) state.downloads.remove(entry) }
    }

    @Test fun savedRepositoryReadsWithoutNetworkAndDeletesLocally() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vault = Vault(context); val original = vault.read("session")
        val state = try {
            vault.save("session", json("token" to "offline-test-only", "account" to "forge-offline-test").toString())
            ForgeState(context.applicationContext as Application)
        } finally { vault.save("session", original) }
        val repo = "forge-offline-test/fixture"
        state.saveOffline(json("repository" to repo, "branch" to "main", "sha" to "a".repeat(40), "saved" to 1L, "omitted" to 2, "files" to json("guide.md" to "# Offline guide\n\nAvailable without a connection.")), state.account)
        try {
            state.open(Page("offline", "Offline copy", repo))
            compose.setContent { ForgeTheme { ForgeApp(state) } }
            compose.waitUntil(10_000) { compose.onAllNodesWithText("guide.md").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("guide.md").performScrollTo().performClick()
            compose.onNodeWithText("Available without a connection.").assertIsDisplayed()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Delete offline copy").performScrollTo().performClick()
            compose.onNodeWithText("Delete local copy").performClick()
            compose.runOnIdle { assertTrue(state.offlineCopies().isEmpty()) }
        } finally {
            if (state.offlineCopies().isNotEmpty()) state.deleteOffline(repo)
        }
    }

    @Test fun returningFromRepositoryKeepsSearchLoadedPagesAndScrollPosition() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vault = Vault(context)
        val original = vault.read("session")
        val state = try {
            vault.save("session", "")
            ForgeState(context.applicationContext as Application)
        } finally { vault.save("session", original) }
        val query = "navigation fixture"
        val selected = "forge-navigation-test/repository-45"
        val cache = requireNotNull(state.api.cache)
        fun seed(path: String, parameters: Map<String, String> = emptyMap(), body: String) {
            // Exercise the real GitHub client without relying on live search results or credentials.
            val key = "${state.api.token}\n${apiUrl(path, parameters)}\nGET\n"
            cache.store(key, body.toByteArray(), null, cache.epoch)
        }
        fun seedPage(page: Int, numbers: IntRange) {
            val rows = numbers.map { number ->
                json("id" to number, "full_name" to "forge-navigation-test/repository-${number.toString().padStart(2, '0')}", "description" to "Navigation fixture $number")
            }
            seed("/search/repositories", mapOf("q" to query, "page" to page.toString(), "per_page" to "30"), json("items" to JSONArray(rows)).toString())
        }
        fun scrollPosition() = compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange))
            .fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()

        var keyboard: SoftwareKeyboardController? = null
        compose.setContent {
            keyboard = LocalSoftwareKeyboardController.current
            ForgeTheme { ForgeApp(state) }
        }
        compose.onNodeWithText("Explore").performClick()
        compose.onNodeWithText("Search repositories or enter owner/name").performTextInput(query)
        compose.runOnIdle { keyboard?.hide() }
        seedPage(1, 1..30)
        compose.onNodeWithText("Search", substring = false).performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("forge-navigation-test/repository-30").fetchSemanticsNodes().isNotEmpty() }
        seedPage(2, 31..45)
        compose.onNodeWithText("Load more").performScrollTo().performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText(selected).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(selected).performScrollTo().assertIsDisplayed()
        val position = scrollPosition()
        assertTrue("The list must be scrolled far enough to expose a later result page", position > 0f)

        // An empty repository needs no branch or README requests for this navigation check.
        seed("/repos/$selected", body = json("id" to 45, "full_name" to selected).toString())
        compose.onNodeWithText(selected).performClick()
        compose.onNodeWithContentDescription("Back").assertIsDisplayed().performClick()

        compose.onNodeWithText("Search repositories or enter owner/name").assertTextContains(query)
        compose.onNodeWithText(selected).assertIsDisplayed()
        assertEquals("Back must restore the same place without loading the result pages again", position, scrollPosition(), 1f)
    }
}
