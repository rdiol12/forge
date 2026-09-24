package app.forge.github

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.json.JSONObject

private const val DISCUSSION = "node_id:id number title body user:author{login} created_at:createdAt updated_at:updatedAt closed isAnswered category{name} repository{nameWithOwner}"
private const val COMMENT = "node_id:id body user:author{login} created_at:createdAt isAnswer replies{totalCount}"

@Composable fun GraphPages(id: Any, load: suspend (String?) -> JSONObject, row: @Composable (JSONObject) -> Unit) {
    val state = LocalForge.current
    val cursors = remember(id, state.refresh) { mutableMapOf<Int, String?>(1 to null) }
    Paged(id, load = { page ->
        if (!cursors.containsKey(page)) emptyList() else {
            val connection = load(cursors[page]); val info = connection.o("pageInfo")
            if (info.optBoolean("hasNextPage")) cursors[page + 1] = info.s("endCursor") else cursors.remove(page + 1)
            connection.rows("nodes")
        }
    }, row = row)
}

@Composable fun Conversations(page: Page) {
    val state = LocalForge.current; var search by remember { mutableStateOf("") }; var query by remember { mutableStateOf("") }; var status by remember { mutableStateOf("open") }
    val kind = page.arg
    Screen {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(search, { search = it }, label = { Text("Search ${page.title.lowercase()}") }, singleLine = true, modifier = Modifier.weight(1f))
            TextButton(onClick = { query = search.trim() }) { Text("Search") }
        }
        if (kind != "discussion") Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf("open", "closed", "all").forEach { value -> FilterChip(status == value, { status = value }, { Text(value.replaceFirstChar { it.uppercase() }) }) } }
        if (kind == "issue" && page.repo.isNotEmpty() && state.connected) OutlinedButton(onClick = { state.open(Page("newIssue", "Create new issue", page.repo)) }) { Text("New issue") }
        Group {
            val scope = if (page.repo.isNotBlank()) "repo:${page.repo}" else "involves:${state.account}"
            if (page.repo.isBlank() && !state.connected) Note("Connect GitHub in Settings to see your conversations.")
            else if (kind == "discussion") GraphPages(query, load = { cursor ->
                state.api.gql("query(\$q:String!,\$cursor:String){search(query:\$q,type:DISCUSSION,first:30,after:\$cursor){nodes{... on Discussion{$DISCUSSION}}pageInfo{hasNextPage endCursor}}}", json("q" to "$scope $query sort:updated", "cursor" to cursor)).o("search")
            }) { ConversationRow(page.repo, kind, it) }
            else Paged(query to status, load = { number ->
                require(number <= 34) { "GitHub search caps results at 1,000. Narrow your search." }
                state.api.obj("/search/issues", mapOf("q" to "is:${if (kind == "pull") "pr" else "issue"} $scope ${if (status == "all") "" else "is:$status"} $query", "sort" to "updated", "order" to "desc", "per_page" to "30", "page" to number.toString())).rows("items")
            }) { ConversationRow(page.repo, kind, it) }
        }
    }

}

@Composable fun ConversationRow(repo: String, kind: String, item: JSONObject) {
    val state = LocalForge.current
    val fullName = repo.ifBlank { item.o("repository").s("nameWithOwner").ifBlank { item.s("repository_url").substringAfter("https://api.github.com/repos/") } }
    RowLink(item.s("title"), "$fullName #${item.optLong("number")} · ${item.o("user").s("login")} · ${item.s("state").ifBlank { if (item.optBoolean("closed")) "closed" else "open" }}", when (kind) { "issue" -> R.drawable.ic_issue_opened; "pull" -> R.drawable.ic_git_pull_request; else -> R.drawable.ic_comment_discussion }, if (item.s("state") == "closed" || item.optBoolean("closed")) Color(0xFF8250DF) else Color(0xFF1A7F37)) {
        state.open(Page(kind, "#${item.optLong("number")}", repository(fullName), positiveID(item.s("number"))))
    }
}

private fun discussionVariables(page: Page, cursor: String? = null) = json("owner" to repository(page.repo).substringBefore('/'), "name" to page.repo.substringAfter('/'), "number" to positiveID(page.id).toInt(), "cursor" to cursor)

@Composable fun ConversationScreen(page: Page) {
    var draftChange by rememberSaveable { mutableStateOf(false) }
    val state = LocalForge.current; var comment by rememberSaveable { mutableStateOf(false) }; var edit by rememberSaveable { mutableStateOf(false) }; var review by rememberSaveable { mutableStateOf<String?>(null) }; var merge by rememberSaveable { mutableStateOf<String?>(null) }
    val repoPath = "/repos/${repository(page.repo)}"; val number = positiveID(page.id)
    Screen { Loaded(page, load = {
        val item = if (page.kind == "discussion") state.api.gql("query(\$owner:String!,\$name:String!,\$number:Int!){repository(owner:\$owner,name:\$name){discussion(number:\$number){$DISCUSSION}}}", discussionVariables(page)).o("repository").getJSONObject("discussion")
            else state.api.obj("$repoPath/${if (page.kind == "pull") "pulls" else "issues"}/$number")
        item to state.api.obj(repoPath)
    }) { (item, repo) ->
        val permissions = repo.o("permissions"); val manager = permissions.optBoolean("push") || permissions.optBoolean("admin") || permissions.optBoolean("triage") || permissions.optBoolean("maintain")
        val sha = item.o("head").s("sha")
        Text(item.s("title"), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text("${page.repo} #$number · ${item.s("state").ifBlank { if (item.optBoolean("closed")) "closed" else "open" }}", color = MaterialTheme.colorScheme.onSurfaceVariant)
        RowLink(item.o("user").s("login"), item.s("created_at").take(10), R.drawable.ic_person) { state.open(Page("profile", item.o("user").s("login"), id = item.o("user").s("login"))) }
        if (page.kind == "pull") Note("${item.o("head").s("label")} → ${item.o("base").s("label")}\n${sha.take(12)} · ${if (item.optBoolean("merged")) "Merged" else "Merge status: ${item.s("mergeable_state")}"}")
        Markdown(item.s("body"))
        if (state.connected) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { comment = true }) { Text("Comment") }
                if (page.kind == "issue" && (manager || item.o("user").s("login") == state.account)) OutlinedButton(onClick = { edit = true }) { Text("Edit issue") }
            }
            WatchControl(item.s("node_id"))
        }
        if (page.kind == "pull") {
            Group {
                RowLink("Changed files", "${item.optInt("changed_files")} files", R.drawable.ic_repo) { state.open(Page("diffs", "Changed files", page.repo, number, sha = sha)) }
                RowLink("Review conversations", icon = R.drawable.ic_comment_discussion) { state.open(Page("threads", "Review conversations", page.repo, number)) }
            }
            if (state.connected && validSha(sha) && item.s("state") == "open") {
                if (permissions.optBoolean("push") || item.o("user").s("login") == state.account) {
                    OutlinedButton(onClick = { draftChange = true }) { Text(if (item.optBoolean("draft")) "Ready for review" else "Convert to draft") }
                    if (draftChange) EditDialog(if (item.optBoolean("draft")) "Mark ready for review?" else "Convert to draft?", emptyList(), "${page.repo} #$number", "Confirm", dismiss = { draftChange = false }) { state.api.setPullDraft(item.s("node_id"), !item.optBoolean("draft")) }
                }
                Group("Review") { listOf("COMMENT" to "Comment review", "APPROVE" to "Approve", "REQUEST_CHANGES" to "Request changes").forEach { (event, label) -> TextButton(onClick = { review = event }) { Text(label) } } }
                if (permissions.optBoolean("push") && !item.optBoolean("draft")) Group("Merge") {
                    listOf("merge" to "allow_merge_commit", "squash" to "allow_squash_merge", "rebase" to "allow_rebase_merge").filter { repo.optBoolean(it.second) }.forEach { (method, _) ->
                        TextButton(onClick = { merge = method }) { Text(when (method) { "merge" -> "Create merge commit"; "squash" -> "Squash and merge"; else -> "Rebase and merge" }) }
                    }
                    Note("GitHub enforces branch rules and required checks. Merges use the displayed head commit.")
                }
            }
            Group("Reviews") { Paged("reviews-$number", load = { state.api.list("$repoPath/pulls/$number/reviews", it) }) { entry -> CommentCard(entry, label = entry.s("state").replace('_', ' ')) } }
        }
        Group("Comments") {
            if (page.kind == "discussion") GraphPages("discussion-$number", load = { cursor ->
                state.api.gql("query(\$owner:String!,\$name:String!,\$number:Int!,\$cursor:String){repository(owner:\$owner,name:\$name){discussion(number:\$number){comments(first:30,after:\$cursor){nodes{$COMMENT}pageInfo{hasNextPage endCursor}}}}}", discussionVariables(page, cursor)).o("repository").o("discussion").o("comments")
            }) { entry ->
                CommentCard(entry, if (entry.optBoolean("isAnswer")) "Accepted answer" else "")
                TextButton(onClick = { state.open(Page("replies", "Replies", page.repo, entry.s("node_id"), arg = item.s("node_id"))) }) { Text("${entry.o("replies").optInt("totalCount")} replies · Reply") }
            } else Paged("comments-$number", load = { state.api.list("$repoPath/issues/$number/comments", it) }) { CommentCard(it) }
        }
        if (comment) EditDialog("Add a comment", listOf(Field("Comment", multiline = true)), "Post to ${page.repo} #$number.", "Post comment", dismiss = { comment = false }) { values ->
            require(values[0].isNotBlank()) { "Enter a comment." }
            if (page.kind == "discussion") discussionReply(state.api, item.s("node_id"), null, values[0]) else state.api.change("$repoPath/issues/$number/comments", body = json("body" to values[0]))
        }
        if (edit) {
            val fields = listOf(Field("Title", item.s("title")), Field("Description", item.s("body"), true)) + if (manager) listOf(Field("Labels (comma separated)", item.rows("labels").joinToString(", ") { it.s("name") }), Field("Assignees (comma separated logins)", item.rows("assignees").joinToString(", ") { it.s("login") })) else emptyList()
            EditDialog("Edit issue", fields, "Save changes to ${page.repo} #$number. Use existing repository label names and valid assignee logins.", dismiss = { edit = false }) { values ->
                fun names(value: String) = value.split(',').map { it.trim() }.filter { it.isNotEmpty() }.distinct()
                state.api.editIssue(page.repo, number, item, values[0], values[1], if (manager) names(values[2]) else null, if (manager) names(values[3]) else null)
            }
        }
        review?.let { event -> EditDialog(event.replace('_', ' '), listOf(Field("Review comment", multiline = true)), "Submit a review for ${page.repo} #$number at ${sha.take(12)}.", "Submit review", dismiss = { review = null }) { values ->
            require(event == "APPROVE" || values[0].isNotBlank()) { "Add a review comment." }
            state.api.change("$repoPath/pulls/$number/reviews", body = json("commit_id" to sha, "event" to event, "body" to values[0]))
        } }
        merge?.let { method -> EditDialog("Merge pull request?", emptyList(), "${page.repo} #$number\n${item.o("head").s("label")} → ${item.o("base").s("label")}\nMethod: $method\nHead: $sha\nGitHub will reject the merge if the head or required checks changed.", "Merge", dismiss = { merge = null }) {
            val result = state.api.change("$repoPath/pulls/$number/merge", "PUT", mergeBody(sha, method))
            require(result.optBoolean("merged")) { result.s("message").ifBlank { "GitHub did not merge this pull request." } }
        } }
    } }
}

@Composable fun CommentCard(comment: JSONObject, label: String = "") {
    val state = LocalForge.current
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TextButton(onClick = { val login = comment.o("user").s("login"); state.open(Page("profile", login, id = login)) }) { Text(comment.o("user").s("login").ifBlank { "Deleted account" }) }
        Text(listOf(label, comment.s("created_at").take(10)).filter { it.isNotBlank() }.joinToString(" · "), style = MaterialTheme.typography.labelSmall)
        Markdown(comment.s("body"))
        if (comment.s("diffHunk").isNotBlank()) Text(comment.s("diffHunk"), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable fun WatchControl(id: String) {
    val state = LocalForge.current; var confirm by rememberSaveable { mutableStateOf(false) }
    Loaded("watch-$id", load = { state.api.gql("query(\$id:ID!){node(id:\$id){... on Subscribable{viewerSubscription}}}", json("id" to id)).o("node").s("viewerSubscription") }) { subscription ->
        if (subscription in listOf("SUBSCRIBED", "UNSUBSCRIBED", "IGNORED")) TextButton(onClick = { confirm = true }) { Text(if (subscription == "SUBSCRIBED") "Unwatch conversation" else "Watch conversation") }
        if (confirm) EditDialog(if (subscription == "SUBSCRIBED") "Unwatch conversation?" else "Watch conversation?", emptyList(), "Change your GitHub notification subscription for this conversation.", "Confirm", dismiss = { confirm = false }) {
            val next = if (subscription == "SUBSCRIBED") "UNSUBSCRIBED" else "SUBSCRIBED"
            val result = state.api.gql("mutation(\$id:ID!,\$state:SubscriptionState!){updateSubscription(input:{subscribableId:\$id,state:\$state}){subscribable{viewerSubscription}}}", json("id" to id, "state" to next))
            require(result.o("updateSubscription").o("subscribable").s("viewerSubscription") == next) { "GitHub did not confirm the watch state." }
        }
    }
}

suspend fun discussionReply(api: GitHub, discussion: String, parent: String?, body: String) {
    require(discussion.isNotBlank() && body.isNotBlank())
    val result = api.gql("mutation(\$id:ID!,\$reply:ID,\$body:String!){addDiscussionComment(input:{discussionId:\$id,replyToId:\$reply,body:\$body}){comment{id}}}", json("id" to discussion, "reply" to parent, "body" to body))
    require(result.o("addDiscussionComment").o("comment").s("id").isNotBlank()) { "GitHub did not confirm this comment. Refresh before retrying." }
}

@Composable fun DiscussionReplies(page: Page) {
    val state = LocalForge.current; var reply by rememberSaveable { mutableStateOf(false) }
    Screen {
        if (state.connected) OutlinedButton(onClick = { reply = true }) { Text("Reply") }
        Group { GraphPages(page.id, load = { cursor -> state.api.gql("query(\$id:ID!,\$cursor:String){node(id:\$id){... on DiscussionComment{replies(first:30,after:\$cursor){nodes{$COMMENT}pageInfo{hasNextPage endCursor}}}}}", json("id" to page.id, "cursor" to cursor)).o("node").o("replies") }) { CommentCard(it, if (it.optBoolean("isAnswer")) "Accepted answer" else "") } }
    }
    if (reply) EditDialog("Reply to discussion", listOf(Field("Reply", multiline = true)), confirm = "Post reply", dismiss = { reply = false }) { discussionReply(state.api, page.arg, page.id, it[0]) }
}

@Composable fun PullFiles(page: Page) {
    var filter by rememberSaveable { mutableStateOf("") }
    val state = LocalForge.current; var lineComment by rememberSaveable { mutableStateOf<String?>(null) }; var revision by remember { mutableStateOf(page.sha) }
    Screen {
        Note("Tap + beside a line to add an inline review comment. Diff comments are pinned to the displayed commit.")
        OutlinedTextField(filter, { filter = it }, label = { Text("Filter loaded files by name or path") }, modifier = Modifier.fillMaxWidth())
        Group { Paged(page, visible = { it.s("filename").contains(filter, true) }, load = { number ->
            val path = "/repos/${repository(page.repo)}/pulls/${positiveID(page.id)}"
            val before = state.api.obj(path).o("head").s("sha")
            require(validSha(before) && (number == 1 || before == revision)) { "Pull request changed. Refresh to reload its diff." }
            val files = state.api.list("$path/files", number)
            require(state.api.obj(path).o("head").s("sha") == before) { "Pull request changed while loading. Refresh to reload." }; revision = before; files
        }) { file ->
            Text(file.s("filename"), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(12.dp))
            Text("+${file.optInt("additions")} −${file.optInt("deletions")} · ${file.s("status")}", modifier = Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.bodySmall)
            if (file.s("patch").isBlank()) Note("GitHub omitted this binary or large diff.")
            else Column(Modifier.horizontalScroll(rememberScrollState())) { diffLines(file.s("patch")).forEach { line ->
                Row(Modifier.background(when { line.text.startsWith('+') -> Color(0x222DA44E); line.text.startsWith('-') -> Color(0x22CF222E); else -> Color.Transparent }).padding(horizontal = 6.dp)) {
                    if (state.connected && line.side != null) TextButton(onClick = { lineComment = json("path" to file.s("filename"), "line" to line.number, "side" to line.side, "sha" to revision).toString() }, contentPadding = PaddingValues(4.dp), modifier = Modifier.width(40.dp).height(34.dp)) { Text("+") } else Spacer(Modifier.width(40.dp))
                    Text("${line.old ?: ""}".padStart(4) + " " + "${line.new ?: ""}".padStart(4) + "  " + line.text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 8.dp))
                }
            } }
        } }
    }
    lineComment?.let { saved -> val line = JSONObject(saved); EditDialog("Comment on line ${line.getInt("line")}", listOf(Field("Comment", multiline = true)), "${line.s("path")} · ${line.s("side")}\nCommit ${line.s("sha").take(12)}", "Post comment", dismiss = { lineComment = null }) { values ->
        require(values[0].isNotBlank() && validSha(line.s("sha")) && safePath(line.s("path")))
        state.api.change("/repos/${page.repo}/pulls/${page.id}/comments", body = json("body" to values[0], "commit_id" to line.s("sha"), "path" to line.s("path"), "line" to line.getInt("line"), "side" to line.s("side")))
    } }
}

@Composable fun ReviewThreads(page: Page) {
    val state = LocalForge.current
    Screen { Group { GraphPages(page, load = { cursor ->
        state.api.gql("query(\$owner:String!,\$name:String!,\$number:Int!,\$cursor:String){repository(owner:\$owner,name:\$name){pullRequest(number:\$number){reviewThreads(first:30,after:\$cursor){nodes{id path line isResolved}pageInfo{hasNextPage endCursor}}}}}", discussionVariables(page, cursor)).o("repository").o("pullRequest").o("reviewThreads")
    }) { thread -> RowLink(thread.s("path"), "Line ${thread.optInt("line")} · ${if (thread.optBoolean("isResolved")) "Resolved" else "Unresolved"}", R.drawable.ic_comment_discussion) { state.open(Page("thread", "Review conversation", page.repo, thread.s("id"))) } } } }
}

@Composable fun ReviewThreadScreen(page: Page) {
    val state = LocalForge.current; var confirm by rememberSaveable { mutableStateOf(false) }
    Screen { Loaded(page, load = { state.api.gql("query(\$id:ID!){node(id:\$id){... on PullRequestReviewThread{isResolved viewerCanResolve viewerCanUnresolve}}}", json("id" to page.id)).getJSONObject("node") }) { thread ->
        val resolved = thread.optBoolean("isResolved")
        Text(if (resolved) "Resolved" else "Unresolved", style = MaterialTheme.typography.titleMedium)
        if (thread.optBoolean(if (resolved) "viewerCanUnresolve" else "viewerCanResolve")) OutlinedButton(onClick = { confirm = true }) { Text(if (resolved) "Reopen conversation" else "Resolve conversation") }
        Group { GraphPages(page.id, load = { cursor -> state.api.gql("query(\$id:ID!,\$cursor:String){node(id:\$id){... on PullRequestReviewThread{comments(first:30,after:\$cursor){nodes{node_id:id body user:author{login} created_at:createdAt diffHunk}pageInfo{hasNextPage endCursor}}}}}", json("id" to page.id, "cursor" to cursor)).o("node").o("comments") }) { CommentCard(it) } }
        if (confirm) EditDialog(if (resolved) "Reopen conversation?" else "Resolve conversation?", emptyList(), "Update this review conversation on GitHub.", "Confirm", dismiss = { confirm = false }) {
            val mutation = if (resolved) "unresolveReviewThread" else "resolveReviewThread"
            val result = state.api.gql("mutation(\$id:ID!){result:$mutation(input:{threadId:\$id}){thread{isResolved}}}", json("id" to page.id))
            require(result.o("result").o("thread").optBoolean("isResolved") == !resolved) { "GitHub did not confirm the conversation state." }
        }
    } }
}
