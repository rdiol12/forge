package app.forge.github

import org.junit.Assert.*
import org.junit.Test
import java.net.URI

class CoreTest {
    @Test fun downloadLinksSurviveStorageAndNeverCopyTemporaryCredentials() {
        val spec = DownloadSpec("/repos/owner/repo/releases/assets/1", "app.apk", sourceURL = "https://github.com/owner/repo/releases/download/v1/app.apk")
        assertEquals(spec.sourceURL, spec.downloadURL)
        assertEquals(spec.downloadURL, DownloadSpec.from(spec.json()).downloadURL)
        assertEquals("https://api.github.com/repos/owner/repo/releases/assets/1", DownloadSpec.from(spec.json().apply { remove("sourceURL") }).downloadURL)
        assertEquals("https://raw.githubusercontent.com/owner/repo/main/file.txt", spec.copy(sourceURL = "https://raw.githubusercontent.com/owner/repo/main/file.txt?token=private#fragment").downloadURL)
        for (url in listOf("https://release-assets.githubusercontent.com/file?sig=temporary", "https://github.com.evil.test/file", "https://token@github.com/file")) assertEquals("https://api.github.com/repos/owner/repo/releases/assets/1", spec.copy(sourceURL = url).downloadURL)
    }

    @Test fun separateReadmeEditsMergeButOverlappingEditsNeedAChoice() {
        val base = "# Project\n\nInstall\nold command\n\nLicense\nMIT\n"
        val current = base.replace("# Project", "# Forge")
        val changed = base.replace("old command", "new command")
        assertEquals(current.replace("old command", "new command"), GitHistory.mergeText(base, current, changed))
        assertNull(GitHistory.mergeText(base, base.replace("old command", "mine"), base.replace("old command", "theirs")))
        assertEquals(changed, GitHistory.mergeText(base, changed, changed))
        assertNull(GitHistory.mergeText("a\nb", "a\nx\nb", "a\ny\nb"))
        assertEquals("A\r\nb\r\nC", GitHistory.mergeText("a\r\nb\r\nc", "A\r\nb\r\nc", "a\r\nb\r\nC"))
    }
    @Test fun offlineCopiesRejectUnsafePathsAndOversizedContent() {
        val copy = json("repository" to "owner/repo", "branch" to "main", "sha" to "a".repeat(40), "saved" to 1L, "omitted" to 2, "files" to json("docs/README.md" to "hello"))
        assertTrue(validOfflineCopy(copy))
        copy.put("files", json("../escape" to "secret")); assertFalse(validOfflineCopy(copy))
        copy.put("files", json("large.txt" to "a".repeat(1_048_577))); assertFalse(validOfflineCopy(copy))
    }
    @Test fun readmeOutlineHandlesDuplicateHeadingsAndEscapesLabels() {
        val doc = ReadmeDocument("<h1>Build &amp; test</h1><h2><code>Install</code></h2><h2>Install</h2>", "owner/repo", "a".repeat(40), "README.md")
        assertEquals(listOf("Build & test", "Install", "Install"), doc.headings.map { it.title })
        assertEquals(listOf("forge-section-0", "forge-section-1", "forge-section-2"), doc.headings.map { it.id })
        assertTrue(doc.page(false, true).contains("href=\"#forge-section-2\""))
        assertTrue(doc.page(false, true).contains("Build &amp; test"))
    }
    @Test fun deploymentReviewRejectsMissingCommentOrInvalidEnvironment() {
        assertThrows(IllegalArgumentException::class.java) { deploymentReviewBody(0, true, "reviewed") }
        assertThrows(IllegalArgumentException::class.java) { deploymentReviewBody(7, true, "  ") }
        val body = deploymentReviewBody(7, false, "Hold for testing")
        assertEquals("rejected", body.getString("state"))
        assertEquals(7, body.getJSONArray("environment_ids").getInt(0))
        assertEquals("Hold for testing", body.getString("comment"))
    }
    @Test fun historyPreservesUnrelatedFilesAndGitRejectsConcurrentUpdates() {
        val a = GitTreeEntry("a.txt", "100644", "blob", "a".repeat(40)); val b = a.copy(sha = "b".repeat(40)); val extra = a.copy(path = "extra.txt")
        assertEquals(mapOf(a.path to a, extra.path to extra), GitHistory.apply(mapOf(b.path to b), mapOf(a.path to a), mapOf(b.path to b, extra.path to extra)))
        assertThrows(IllegalArgumentException::class.java) { GitHistory.apply(mapOf(a.path to a), mapOf(b.path to b), emptyMap()) }
        val folder = java.nio.file.Files.createTempDirectory("forge-git-test").toFile()
        try {
            fun git(vararg args: String, input: ByteArray = byteArrayOf()): ByteArray {
                val builder = ProcessBuilder(listOf("git", "-C", folder.path) + args)
                builder.environment().putAll(mapOf("GIT_AUTHOR_NAME" to "Test", "GIT_AUTHOR_EMAIL" to "test@example.invalid", "GIT_COMMITTER_NAME" to "Test", "GIT_COMMITTER_EMAIL" to "test@example.invalid"))
                val process = builder.start(); process.outputStream.use { it.write(input) }; val output = process.inputStream.readBytes(); process.waitFor(); return output
            }
            fun ByteArray.text() = toString(Charsets.UTF_8).trim()
            git("init", "--bare", "-q")
            val tree = git("hash-object", "-t", "tree", "-w", "--stdin").text()
            val old = git("commit-tree", tree, "-m", "Original").text()
            val new = git("commit-tree", tree, "-p", old, "-m", "Next").text()
            git("update-ref", "refs/heads/main", old)
            GitHistory.validateReport(git("receive-pack", "--stateless-rpc", folder.path, input = GitHistory.pushPacket("main", old, new)), "main")
            assertThrows(IllegalArgumentException::class.java) { GitHistory.validateReport(git("receive-pack", "--stateless-rpc", folder.path, input = GitHistory.pushPacket("main", old, old)), "main") }
            assertEquals(new, git("rev-parse", "refs/heads/main").text())
        } finally { folder.deleteRecursively() }
    }
    @org.junit.Test fun memoryCacheRejectsOversizedAndLateResponsesAfterRefresh() {
        val cache = APIMemoryCache(capacity = 8)
        val epoch = cache.epoch
        cache.store("first-account", "first".toByteArray(), "one", epoch)
        org.junit.Assert.assertEquals("first", cache.value("first-account")!!.bytes.toString(Charsets.UTF_8))
        org.junit.Assert.assertNull(cache.value("second-account"))
        cache.clear()
        cache.store("first-account", "stale".toByteArray(), "one", epoch)
        org.junit.Assert.assertNull(cache.value("first-account"))
        cache.store("first-account", ByteArray(9), "one", cache.epoch)
        org.junit.Assert.assertNull(cache.value("first-account"))
    }
    @org.junit.Test fun readmeImagesStayPinnedAndIssueMetadataIsExplicit() {
        val document = ReadmeDocument("<img src=\"../images/a%20b.png\"><img src=\"https://example.com/badge.svg\"><img src=\"javascript:alert(1)\">", "owner/repo", "a".repeat(40), "docs/README.md")
        org.junit.Assert.assertTrue(document.html.contains("forge-readme://image/images/a%20b.png"))
        org.junit.Assert.assertTrue(document.html.contains("https://example.com/badge.svg"))
        org.junit.Assert.assertFalse(document.html.contains("javascript:alert"))
        org.junit.Assert.assertEquals("images/a b.png", document.imagePath(java.net.URI("forge-readme://image/images/a%20b.png")))
        org.junit.Assert.assertNull(document.imagePath(java.net.URI("https://api.github.com/user")))
        val body = issueFields("  Example  ", "Details", listOf("octocat"), listOf("bug"), 4)
        org.junit.Assert.assertEquals("Example", body.getString("title"))
        org.junit.Assert.assertEquals(4, body.getInt("milestone"))
        org.junit.Assert.assertFalse(body.has("project"))
        org.junit.Assert.assertTrue(runCatching { issueFields(" ", "") }.isFailure)
        org.junit.Assert.assertTrue(runCatching { issueFields("Issue", "", listOf("../bad")) }.isFailure)
    }
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
