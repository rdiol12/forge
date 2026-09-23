# Public feedback translated into Forge improvements

Reviewed 2026-09-23. GitHub Mobile feedback is in the community/community Discussions Mobile category; github/mobile is not a public source repository. These reports describe requests or experiences, not verified defects in every current official-app version.

| Public report | What Forge does | Status |
| --- | --- | --- |
| [Download debug artifacts in the app, avoiding another browser login](https://github.com/orgs/community/discussions/28572) | Authenticated artifact downloads use the app token, with native save/share. Browser OAuth sign-in uses PKCE and Keychain. | Downloads shipped; OAuth implementation requires app registration and backend activation. |
| [Download individual repository files](https://github.com/orgs/community/discussions/208392) | Native folder browser, raw-file downloads, Quick Look preview, and Save to Files, including accessible private repositories. The report is Android feedback; the same capability is useful on iOS. | Implemented in 0.3. |
| [Keep Profile accessible and let users hide Copilot](https://github.com/orgs/community/discussions/189689) | Profile retains its tab. Copilot is a local Home preference, off by default, under Settings. | Implemented in 0.3. |
| [Expose release download counters](https://github.com/orgs/community/discussions/22845) | Read exact per-asset counts and totals from GitHub; refresh on demand. | Shipped. GitHub does not expose Actions artifact download counts. |
| [Display Actions step summaries](https://github.com/orgs/community/discussions/164812) | Keep the full run link available. | Deferred: the public jobs API supplies steps and logs, not arbitrary step-summary Markdown. No undocumented scraping. |

Additional visual corrections in 0.3: compact Home rows, neutral row labels, clearer section alignment, and separate toolbar items. The iOS 26 shell uses native system chrome and MIT-licensed Octicons. Collaboration detail pages still use the GitHub web interface.

No upstream issues or comments were posted, and no claim is made that these changes fix GitHub's own app or API.
