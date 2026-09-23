package app.forge.github

import org.junit.Assert.*
import org.junit.Test
import java.net.URI

class CoreTest {
    @Test fun apiPathsAndStorageNeverLeakCredentials() {
        assertEquals("https://api.github.com/repos/a/b/contents/a%23b?ref=feature%2Fa", apiUrl("/repos/a/b/contents/a#b", mapOf("ref" to "feature/a")).toString())
        for (path in listOf("//evil.test", "/a/../b", "https://evil.test")) assertThrows(IllegalArgumentException::class.java) { apiUrl(path) }
        assertTrue(trustedDownload(URI("https://release-assets.githubusercontent.com/a")))
        assertFalse(trustedDownload(URI("https://githubusercontent.com.evil.test/a")))
        assertFalse(trustedDownload(URI("http://codeload.github.com/a")))
        assertFalse(backgroundLocation(URI("https://api.github.com/a")))
        assertTrue(backgroundLocation(URI("https://codeload.github.com/a")))
        assertEquals("_a_b", safeName("/a:b"))
        assertTrue(safeName("x".repeat(300)).toByteArray().size <= 180)
    }
    @Test fun callbacksRequireExactOriginSingleStateAndPkce() {
        val attempt = OAuthAttempt("state", "verifier")
        assertEquals("code", attempt.code("app.forge.github://oauth/callback?state=state&code=code"))
        for (uri in listOf("app.forge.github://oauth/callback?state=state&state=state&code=code", "app.forge.github://evil/callback?state=state&code=code", "app.forge.github://oauth/callback?state=wrong&code=code", "app.forge.github://oauth/callback?state=state&code=code#fragment"))
            assertThrows(IllegalArgumentException::class.java) { attempt.code(uri) }
        assertEquals("iMnq5o6zALKXGivsnlom_0F5_WYda32GHkxlV7mq7hQ", OAuthAttempt("x", "verifier").challenge())
    }
    @Test fun mutationPayloadsPinRevisionsAndDoNotTouchUneditedFields() {
        val sha = "a".repeat(40)
        val file = fileEdit(sha, "feature/fix", "hello", "Update README")
        assertEquals(sha, file.getString("sha")); assertEquals("feature/fix", file.getString("branch"))
        assertEquals("aGVsbG8=", file.getString("content"))
        assertThrows(IllegalArgumentException::class.java) { fileEdit("main", "main", "x", "y") }
        val merge = mergeBody(sha, "squash")
        assertEquals(sha, merge.getString("sha")); assertEquals("squash", merge.getString("merge_method"))
        assertEquals(setOf("name", "body", "prerelease"), releaseEdit("name", "notes", true).keys().asSequence().toSet())
        assertTrue(validBranch("feature/login")); assertFalse(validBranch("../main")); assertFalse(validBranch("main.lock"))
    }
    @Test fun diffCoordinatesTrackEachSide() {
        val lines = diffLines("@@ -10,2 +20,2 @@\n same\n-old\n+new\n\\ No newline at end of file")
        assertNull(lines[0].side)
        assertEquals(10, lines[1].old); assertEquals(20, lines[1].new)
        assertEquals("LEFT", lines[2].side); assertEquals(11, lines[2].number)
        assertEquals("RIGHT", lines[3].side); assertEquals(21, lines[3].number)
        assertNull(lines[4].side)
    }

    @Test fun nativeLinksAndCodePreserveTheirDestinationsAndText() {
        assertEquals(Page("people", "Following", id = "octocat", arg = "following"), route("https://github.com/octocat?tab=following"))
        assertEquals("pull", route("https://api.github.com/repos/owner/repo/pulls/12")?.kind)
        assertEquals("feature/login/src/Main.kt", route("https://github.com/owner/repo/blob/feature/login/src/Main.kt")?.arg)
        assertNull(route("https://github.com.evil.test/owner/repo"))
        val source = "// Unicode: שלום 😀\nval name = \"hello\"\n"
        assertEquals(source, highlight(source, false).joinToString("\n") { it.text })
        val blocks = markdownBlocks("# Heading\n\n```swift\n# not a heading\n```\n- item")
        assertEquals(listOf("h1", "code", "text"), blocks.map { it.first })
        assertEquals("# not a heading", blocks[1].second)
    }
}
