# Public feedback translated into Forge improvements

Reviewed 2026-09-23. GitHub Mobile feedback is in the community/community Discussions Mobile category; github/mobile is not a public source repository. These reports describe requests or experiences, not verified defects in every current official-app version.

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

The private Forge issue tracker had no filed issues at the time of this review. GitHub Mobile already supports workflow logs and rerun/cancel controls ([official Actions announcement](https://github.com/orgs/community/discussions/54943)); those are not claimed as missing official-app features. Forge's remaining limits include push delivery, merge queues/conflict editing, arbitrary workflow step-summary Markdown, and complete Markdown rendering.
