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
    @Test fun longPressCopiesTheDownloadLinkWithoutStartingADownload() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val state = ForgeState(context.applicationContext as Application)
        val spec = DownloadSpec("/repos/owner/repo/releases/assets/1", "app.apk", sourceURL = "https://github.com/owner/repo/releases/download/v1/app.apk")
        val initial = state.downloads.entries.size
        compose.setContent { ForgeTheme { androidx.compose.runtime.CompositionLocalProvider(LocalForge provides state) { DownloadButton(spec) } } }
        compose.onNodeWithText("Download").performTouchInput { longClick() }
        compose.onNodeWithText("Copy download link").assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertEquals(spec.downloadURL, context.getSystemService(android.content.ClipboardManager::class.java).primaryClip!!.getItemAt(0).text.toString())
            assertEquals(initial, state.downloads.entries.size)
        }
    }
    @Test fun homePullRequestsShowContributionsToOwnedRepositories() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vault = Vault(context); val original = vault.read("session")
        val state = try {
            vault.save("session", json("token" to "search-test-only", "account" to "owner").toString())
            ForgeState(context.applicationContext as Application)
        } finally { vault.save("session", original) }
        val cache = requireNotNull(state.api.cache)
        fun seed(scope: String, advanced: Boolean, body: String) {
            val parameters = mapOf("q" to "is:pr $scope is:open ", "sort" to "updated", "order" to "desc", "per_page" to "30", "page" to "1") + if (advanced) mapOf("advanced_search" to "true") else emptyMap()
            cache.store("${state.api.token}\n${apiUrl("/search/issues", parameters)}\nGET\n", body.toByteArray(), null, cache.epoch)
        }
        seed("involves:owner", false, "{\"items\":[]}")
        seed("(user:owner OR involves:owner)", true, """{"items":[{"number":9,"title":"My contribution","repository_url":"https://api.github.com/repos/zed/library","user":{"login":"owner"},"state":"open"},{"number":3,"title":"Add platform support","repository_url":"https://api.github.com/repos/owner/project","user":{"login":"contributor"},"state":"open"}]}""")
        state.open(Page("conversations", "Pull Requests", arg = "pull"))
        compose.setContent { ForgeTheme { ForgeApp(state) } }
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Add platform support").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Add platform support").assertIsDisplayed()
        compose.onNodeWithText("owner/project #3", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Opened by contributor", substring = true).assertIsDisplayed()
        val owned = compose.onNodeWithText("owner/project\nOwner: owner").fetchSemanticsNode().boundsInRoot.top
        val external = compose.onNodeWithText("zed/library\nOwner: zed").fetchSemanticsNode().boundsInRoot.top
        assertTrue("Group by repository even when GitHub returns a different updated order", owned < external)
    }

    @Test fun changedFilesPanelSelectsDiffAndPreservesOldAndNewLines() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val state = ForgeState(context.applicationContext as Application)
        val cache = requireNotNull(state.api.cache); val sha = "a".repeat(40)
        val path = "/repos/owner/project/pulls/3"
        fun seed(endpoint: String, parameters: Map<String, String> = emptyMap(), body: String) {
            cache.store("${state.api.token}\n${apiUrl(endpoint, parameters)}\nGET\n", body.toByteArray(), null, cache.epoch)
        }
        seed(path, body = json("head" to json("sha" to sha)).toString())
        seed("$path/files", mapOf("per_page" to "30", "page" to "1"), JSONArray(listOf(
            json("filename" to "src/First.kt", "status" to "modified", "additions" to 1, "deletions" to 1, "patch" to "@@ -10 +10 @@\n-val old = 1\n+val first = 2"),
            json("filename" to "src/Second.kt", "status" to "modified", "additions" to 1, "deletions" to 1, "patch" to "@@ -20 +21 @@\n-val before = 1\n+val after = 2")
        )).toString())
        state.open(Page("diffs", "Changed files", "owner/project", "3", sha = sha))
        compose.setContent { ForgeTheme { ForgeApp(state) } }
        compose.waitUntil(5_000) { compose.onAllNodesWithContentDescription("Show diff for src/Second.kt").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Show diff for src/Second.kt").performClick()
        compose.onNodeWithText("-val before = 1").assertIsDisplayed()
        compose.onNodeWithText("+val after = 2").assertIsDisplayed()
        compose.onNodeWithContentDescription("Old line 20").assertIsDisplayed()
        compose.onNodeWithContentDescription("New line 21").assertIsDisplayed()
        compose.onNodeWithText("Files", substring = false).performClick()
        compose.onNodeWithContentDescription("Show diff for src/First.kt").performClick()
        compose.onNodeWithText("+val first = 2").assertIsDisplayed()
        compose.onNodeWithText("+val after = 2").assertDoesNotExist()
    }

    @Test fun conflictEditorRequiresAnExplicitChoiceAndKeepsEditedText() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val state = ForgeState(context.applicationContext as Application)
        val before = GitTreeEntry("README.md", "100644", "blob", "a".repeat(40), 4)
        val conflict = HistoryConflict("README.md", before, before.copy(sha = "b".repeat(40)), before.copy(sha = "c".repeat(40)), "base", "requested", "current")
        var result: HistoryResolution? = null
        compose.setContent { ForgeTheme { androidx.compose.runtime.CompositionLocalProvider(LocalForge provides state) { HistoryConflictDialog(conflict, dismiss = {}, resolved = { result = it }) } } }
        compose.onNodeWithText("Use resolution").assertIsNotEnabled()
        compose.onNodeWithText("Edit final file").performScrollTo().performClick()
        compose.onNodeWithText("Final file contents").performScrollTo().performTextReplacement("# My reviewed README\nKeep these changes.")
        compose.onNodeWithText("Use resolution").performClick()
        compose.runOnIdle { assertEquals(HistoryResolution("edit", "# My reviewed README\nKeep these changes."), result) }
    }

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
