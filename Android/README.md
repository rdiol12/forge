# Forge for Android

Native Kotlin and Jetpack Compose, Android 8.0 (API 26) or newer. Open this directory in Android Studio, or use JDK 17+ and an Android SDK:

```sh
./gradlew testDebugUnitTest lintDebug assembleDebug
```

The build pins Gradle 8.13 (including its distribution checksum), Android Gradle Plugin 8.13.2, Kotlin/Compose compiler 2.2.20, and Compose BOM 2025.09.01. [Android build compatibility](https://developer.android.com/build/releases/agp-8-13-0-release-notes).

## Install a release

Download `Forge-android.apk` from the repository's private [Releases](https://github.com/rdiol12/forge-ios/releases). Allow installation from your browser/file manager when Android asks, then install the APK. Release APKs use a persistent signing key, so later builds update the existing app. The debug app uses a separate application ID and can be installed alongside it.

The [Android workflow](https://github.com/rdiol12/forge-ios/actions/workflows/android.yml) builds, tests, checks Android lint, runs emulator UI/Keystore checks, reads private repository/workflow/release data, downloads a real private release and Actions artifact, verifies the APK signature/checksum, and publishes a private prerelease. It also launches the optimized release APK and captures its Home screen. Tags starting `android-v` use that release tag. Branch runs use `android-build-<run>-<attempt>`. Existing releases are never overwritten.

Signing material is stored only in GitHub Actions secrets (`ANDROID_KEYSTORE`, `ANDROID_KEY_PASSWORD`). The protected local backup is in the Windows user's `AppData/Local/ForgeSigning` directory, outside the repository. Keep that key and its password backed up securely: losing it prevents updates to existing installations. The APK contains the public signing certificate, never the private key. [Android app signing](https://developer.android.com/studio/publish/app-signing).

## Features

- Home, Inbox, Explore, Profile; GitHub-style grouped rows, Octicons, native back navigation with separate tab histories, light/dark appearance.
- Native profiles, followers/following, repositories (including accessible private ones), stars, organizations and favorites.
- Owned-repository Actions dashboard, full paged run history, successful builds, test steps, searchable/copyable job logs, rerun/cancel confirmations, artifact downloads.
- Releases with GitHub's per-asset download counts; native notes, edit name/notes/pre-release status, confirmed deletion without deleting the tag.
- Branch switching, commit-pinned file listings/ZIPs/blob downloads, syntax colors, line numbers, search, wrapping, copy, Markdown and JSON previews; README commits with the original SHA to prevent overwriting concurrent edits.
- Native issues, issue creation/title/body/label/assignee editing, comments, watching; Discussions and replies; pull-request reviews, diffs, line comments, review-thread resolution and confirmed merge/squash/rebase using the displayed head SHA.
- Repository visibility changes require admin access, typing the repository name, and explicit confirmation. This UI does not change the Forge repository's visibility during development or testing.
- Persistent download list, Android background transfers for storage redirects, cancellation/retry, Save as and sharing.

## Sign-in and data

Manual personal access token sign-in validates `/user` before saving. Tokens and pending OAuth PKCE verifiers use AES-GCM with a non-exportable Android Keystore key; app backup is disabled. Tokens go only to `https://api.github.com`. Source URLs are fixed to that API, GitHub redirects are validated, and storage requests receive no Authorization or Cookie headers. The system download manager receives only a temporary storage URL after the authenticated API handshake. It never receives the GitHub token.

Browser sign-in uses Custom Tabs and the same PKCE/state-validated backend as iOS. **GitHub OAuth registration/backend activation is still required**; see [Backend setup](../Backend/README.md). The client secret is never in either app. Browser sessions are separate from the app's API connection.

Permission requirements match [the main README](../README.md#connect-github). Android's Inbox needs OAuth or a classic token; GitHub does not support fine-grained tokens for notifications. Disconnect cancels active transfers and clears credentials; favorites and intentionally saved downloads remain.

## Limits and checks

This is private sideload distribution, not a Google Play release. Monitoring refreshes in the app; no push notifications or background repository polling. One GitHub.com account, no Enterprise hosts, merge queue, auto-merge, or conflict editor. Browser OAuth and physical-phone interactions still need end-to-end verification.

Actions artifact counts are unavailable from GitHub and are never invented. Expired artifacts cannot be downloaded. The owned Actions summary shows the latest five runs per repository, with 30 repositories per page; each repository's full run history is paged separately. GitHub caps search at 1,000 results, Contents at 1,000 entries per folder, and PR files at 3,000.

Code previews support UTF-8 up to 1 MiB, and logs preview the first 2 MiB. Syntax colors use lexical matching. Markdown supports headings, paragraphs, lists, quotes, inline formatting/links and fenced code; tables, images and embedded HTML are not fully rendered. Very long generated lines can exceed the horizontal canvas; Wrap and Copy preserve access to the full text. Direct API-file downloads need the process running; archive transfers use DownloadManager. Retry starts a fresh request rather than implementing custom byte-range resume.

Editor drafts and in-flight saves survive screen rotation in the ViewModel, including their original revision checks. Drafts are not persisted after process termination.

Unit tests exercise URL/redirect boundaries, PKCE callbacks, immutable edit/merge payloads, branch validation, native routes, diff coordinates and text preservation. Emulator tests cover navigation, light/dark UI, code search/wrapping/copy, native people routing, real Android Keystore persistence, and read-only private GitHub API/download integration. Mutations are never sent to real repositories as tests. Screenshot people/code fixtures live only in the test APK; the installed app starts empty and displays real data.

Third-party notices are bundled in the app and accessible from Settings.

On 2026-09-23, the first complete emulator pass ran all six original instrumentation tests without skips or failures, including real private release and Actions-artifact downloads. Its screenshot export then exposed Gradle uninstalling the test app; the workflow now executes the built test APK directly and collects screenshots before cleanup.
