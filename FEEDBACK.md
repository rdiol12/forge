# Public feedback translated into Forge improvements

Reviewed 2026-09-24. GitHub Mobile feedback is in the [community/community Discussions Mobile category](https://github.com/community/community/discussions/categories/mobile); github/mobile is not a public source repository. These reports describe requests or experiences, not verified defects in every current official-app version.

## Newly reviewed requests

Scanned the 30 most recently updated Mobile discussions, then read the requests and replies below, including older requests with continued interest. These are proposed additions, not shipped features or a claim to have audited every discussion. Priority reflects Forge's focus on Actions, releases and native reading; votes are a snapshot from GitHub's API on 2026-09-24, not a complete popularity ranking.

| Priority | User request | Votes | Useful addition to Forge / current gap |
| --- | --- | ---: | --- |
| Next | [Approve deployments from an Actions run](https://github.com/orgs/community/discussions/110751) | 42 | Show pending environment reviews on the run screen, with approve/reject and a comment for eligible reviewers. Forge currently has rerun/cancel controls. GitHub staff clarified that their app already supports deployment review through notifications; the reported gap is opening it directly from a run or link. |
| Next | [Markdown heading outline](https://github.com/orgs/community/discussions/204173) | 2 | Add a table of contents that jumps to README/Markdown headings. Complements Forge's rendered images, tables and full-width README without adding another card. |
| Next | [Filter changed files in a PR](https://github.com/orgs/community/discussions/207767) | 1 | Search the changed-file list by name/path. Forge has code search within an opened file, but no filter for PR files. |
| Next | [Copy a file's repository-relative path](https://github.com/orgs/community/discussions/208393) | 1 | Add Copy path alongside existing copy-content/download actions. The original report concerns Android; useful on both platforms. |
| Next | [Convert a ready PR back to draft](https://github.com/orgs/community/discussions/13953) | 59 | Add explicit Draft / Ready for review controls for permitted users. Forge supports reviews and merges but lacks these transitions. The original request acknowledges that GitHub Mobile already supported draft-to-ready. |
| Investigate | [Preserve position when returning to starred repositories](https://github.com/orgs/community/discussions/207613) | 1 | Check navigation restores scroll position, search and filters on both platforms. This is an upstream Android bug report; not yet reproduced as a Forge bug. |
| Larger addition | [Read selected repositories offline](https://github.com/orgs/community/discussions/7365) | 80 | Explicit Keep offline for a selected branch, with last-sync time and storage/delete controls. Forge's short-lived response cache and downloaded files do not provide a browsable offline repository. |
| Larger addition | [Read repository Wiki pages](https://github.com/orgs/community/discussions/9566) | 144 | Native Wiki navigation and rendered pages. Forge has no Wiki reader; first establish a supported way to fetch public and private Wiki content. |

Suggested order: deployment approval, README outline, PR file filtering, Copy path, then draft PR controls. Check list restoration during navigation work; plan offline repositories and Wiki separately. Do not treat old reports as proof a feature is still absent in the latest GitHub Mobile build. For example, [repository creation shipped in GitHub Mobile on 2026-05-11](https://github.blog/changelog/2026-05-11-create-repositories-on-the-go-with-github-mobile/), so older requests for it are not presented here as a new gap in the official app.

## Previously reviewed requests

| Public report | What Forge does | Status |
| --- | --- | --- |
| [Opening notifications does not update read state](https://github.com/orgs/community/discussions/46274) | Opening an Inbox item marks its thread read on GitHub; the unread dot/filter update after the API confirms success. A swipe action also marks it read. Failures leave it unread and show an error. | Implemented in 0.5. This report describes a 2023 beta; Forge also had the missing state-sync behavior. |
| [Create new branches inside the mobile app](https://github.com/orgs/community/discussions/88441) | Repository > Create branch offers a native form. It loads the default source branch, allows a different source, and creates a new ref from that source's commit without overwriting existing refs. | Implemented in 0.5. Requested in 2024 and supported by a further user report in June 2026. Requires Contents write access. |
| [Download debug artifacts in the app, avoiding another browser login](https://github.com/orgs/community/discussions/28572) | Authenticated artifact downloads use the app token, with native save/share. Browser OAuth sign-in uses PKCE and Keychain. | Downloads shipped; OAuth implementation requires app registration and backend activation. |
| [Download individual repository files](https://github.com/orgs/community/discussions/208392) | Native folder browser, raw-file downloads, Quick Look preview, and Save to Files, including accessible private repositories. The report is Android feedback; the same capability is useful on iOS. | Implemented in 0.3. |
| [Keep Profile accessible and let users hide Copilot](https://github.com/orgs/community/discussions/189689) | Profile retains its tab. Copilot is a local Home preference, off by default, under Settings. | Implemented in 0.3. |
| [Expose release download counters](https://github.com/orgs/community/discussions/22845) | Read exact per-asset counts and totals from GitHub; refresh on demand. | Shipped. GitHub does not expose Actions artifact download counts. |
| [Display Actions step summaries](https://github.com/orgs/community/discussions/164812) | Keep the full run link available. | Deferred: the public jobs API supplies steps and logs, not arbitrary step-summary Markdown. No undocumented scraping. |

Additional visual corrections in 0.3: compact Home rows, neutral row labels, clearer section alignment, and separate toolbar items. The iOS 26 shell uses native system chrome and MIT-licensed Octicons. Version 0.4 adds native Issues, Discussions, pull requests, reviews, comments, diffs, and a code reader. Users can create issues, watch conversations, submit reviews, resolve review threads, and merge using permitted methods with a commit check. No push notifications, merge queues, or conflict editor yet. Remaining web destinations open inside Forge. Website sessions are kept separate from the supported OAuth/API connection.

No upstream issues or comments were posted, and no claim is made that these changes fix GitHub's own app or API.

The Forge issue tracker had no filed issues at the earlier review, when the repository was private. GitHub Mobile already supports workflow logs and rerun/cancel controls ([official Actions announcement](https://github.com/orgs/community/discussions/54943)); those are not claimed as missing official-app features. Forge's remaining limits include push delivery, merge queues/conflict editing and arbitrary workflow step-summary Markdown. Repository and profile READMEs now render images and tables; that does not imply full GitHub Markdown parity across every conversation screen.
