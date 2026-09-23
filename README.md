# Forge

A native SwiftUI iOS and Kotlin/Jetpack Compose Android GitHub companion focused on **Actions, releases, and downloading their files**. Working name: Forge. Requires iOS 17 or Android 8.0 or later; no third-party iOS runtime dependencies, analytics, or AI service. Standard browser sign-in uses a small OAuth exchange backend.

## Implemented

- Browser sign-in with GitHub using Apple AuthenticationServices, PKCE, state validation, and Keychain. Activation requires the OAuth registration described in Backend/README.md.
- Read code with syntax colors, line numbers, search, wrapping, and copy; render Markdown headings/lists/code blocks and format JSON. Switch branches in Code, with previews, file downloads and repository ZIPs pinned to the selected revision. Edit README files with a preview and a commit to the selected branch.
- Browse native Issues, Discussions, and pull requests with search, pagination, descriptions, comments, Discussion replies/accepted answers, pull-request reviews, review comments, and changed-file diffs. Inbox conversation links open these screens.
- Create branches from a chosen source branch in a native repository form; the default source is loaded from GitHub. Existing branches are never overwritten.
- Sync notification read state when opening an Inbox item, or swipe to mark it read. Failed writes preserve the unread state.
- Create issues, watch/unwatch conversations on GitHub, submit PR reviews (comment, approve, request changes), and resolve/unresolve review conversations when permitted.
- Merge pull requests with the repository's allowed merge, squash, or rebase methods. A confirmation identifies the repository, branches, and current commit; GitHub rejects a changed head or unmet repository rules.
- Hide the Copilot shortcut in Settings; Profile always stays in the tab bar.
- GitHub-style Home, Inbox, Explore, and Profile tabs with native iOS navigation, grouped lists, repository avatars, blue accents, and GitHub's MIT-licensed Octicons.
- Native Profile shortcuts for account details, your repositories (including accessible private repositories), starred repositories, and organizations. Profile → Your repository Actions opens your repositories' workflows without a Favorites requirement.
- Favorite public or token-accessible private repositories; old watched repositories automatically appear in Favorites.
- Open Actions, Releases, and Downloads from Home shortcuts. Any accessible repository can open Actions and Releases directly, with pagination; Favorites is only required for the combined Home feed.
- Search real GitHub repositories, page through results, and add them to Favorites.
- Browse real GitHub Inbox notifications with All/Unread filters and pagination (OAuth or a classic token required).
- GitHub profile, repository-list, issue, pull-request, Discussion, repository, Actions-list, and Releases-list links resolve to native Forge screens. Remaining web destinations (including Copilot and token creation) open in the in-app Safari sheet. Website login remains separate from Forge's API connection; browser cookies are not accessed or reused.
- See recent Actions runs across repositories, filter failures/active runs, and search by repository, title, or branch.
- Inspect jobs and steps; search/copy native job logs (first 2 MiB), download full logs, re-run all/failed jobs, and cancel active runs with confirmation. Latest build opens the newest successful run and its retained artifacts, with earlier successful runs selectable.
- List Actions artifacts, see their size/expiry, and download available artifacts as ZIPs.
- Follow a release inbox that remembers which releases you have opened.
- See **GitHub's exact per-file release download counts**, with a total for the assets loaded.
- Download release assets, including private ones when your token permits it.
- Track download progress, cancel, retry, and use the native share sheet to **Save to Files**.
- Keep completed downloads in the app's local library, accessible offline and through Files → On My iPhone → Forge → Downloads.

New in 0.7: native follower/following lists; an owned-repository Actions dashboard; latest successful build downloads; searchable job logs; re-run/cancel controls; background archive downloads with persistent retries; issue/label/assignee editing; Discussion replies; PR line comments; repository visibility settings; README commits; release editing/deletion; branch switching, repository ZIPs, syntax colors, Markdown previews and formatted JSON.

The app starts empty and uses real GitHub data. There are no fabricated metrics or demo downloads. Your repository and organization lists reflect the repositories and memberships your connection can access. Fine-grained tokens may need Starring read permission; organization visibility also depends on the token's organization access.

## Download counts: the distinction that matters

| File type | Download | GitHub download count |
| --- | --- | --- |
| Uploaded release asset | Yes; public assets work without a token | Yes, `download_count` per file |
| Actions build artifact | Yes; token with Actions read access required | **Not exposed by GitHub** |

Counts are cumulative download events, not unique users. Forge does not invent Actions counts or substitute its own local downloads for GitHub totals. Expired artifacts cannot be recovered through this API.

Sources: [Release assets](https://docs.github.com/en/rest/releases/assets), [Actions artifacts](https://docs.github.com/en/rest/actions/artifacts).

## Run on an iPhone or simulator

### Download a CI build

The private [forge repository](https://github.com/rdiol12/forge) builds iOS on macOS and Android on Linux. Download `Forge-unsigned.ipa` and `Forge-android.apk` together from [Releases](https://github.com/rdiol12/forge/releases). Sign the IPA with your sideloading tool; the APK is signed and ready to install. You must have access to the private repository to download its releases.

[Build and publish iOS and Android](https://github.com/rdiol12/forge/actions/workflows/ios.yml) runs on pushes to `main`, version tags (`v*`), and manual **Run workflow** requests. Documentation-only branch pushes are skipped. Both apps share the same source commit and build number. Each run:

1. Runs the shared Swift tests and OAuth backend tests.
2. Builds the Release iOS device target with Xcode 26.3 and signing disabled. Native Liquid Glass navigation is available on iOS 26; earlier systems use their native appearance.
3. Builds and launches an iPhone simulator and saves light/dark Home screenshots plus a native issue screenshot as a workflow artifact. The screenshot simulator has four public favorite repositories; installed IPAs still start empty.
4. Packages the app as `Payload/Forge.app` inside an IPA and checks its ZIP integrity and SHA-256 checksum.
5. In parallel, tests/lints Android, builds the signed APK, checks native screens and Keystore on an emulator, and verifies real private repository/artifact downloads. It also launches the optimized release APK and verifies its signature and checksum.
6. Keeps both apps and their checks as Actions artifacts. After **both jobs pass**, one publishing job checks matching app versions and creates **one private release** containing the IPA, APK and a shared `SHA256SUMS`. The release stays a draft until all three files have uploaded successfully. If either build fails, nothing is published.

Branch/manual runs create prereleases named `build-<run>-<attempt>`. Version tags create normal releases. Existing release tags are never overwritten; choose a new version tag for another published version. A failed upload may leave an unpublished draft to remove before retrying that version tag. Build logs are retained on failure.

No Apple credentials are needed. Android uses the existing `ANDROID_KEYSTORE` and `ANDROID_KEY_PASSWORD` secrets for its persistent signing key. The workflow uses GitHub's temporary token; only the final publishing job has repository contents write permission. The IPA is an **unsigned** device build for later signing, not an App Store/TestFlight upload or an immediately installable IPA. GitHub-hosted runner usage is charged against the account's Actions allowance.

### Build locally

1. On a Mac with **Xcode 26.3 or newer**, open `Forge.xcodeproj`.
2. Select the **Forge** scheme and an iPhone simulator, then Run.
3. For a physical iPhone, choose your Apple development team in Signing & Capabilities and change `app.forge.github` to your own unique bundle identifier.
4. Tap **+** and add a repository as `owner/name`, such as `cli/cli`.
5. Open a release, tap **Download**, then **Save to Files or share**. Actions artifacts are under the individual run.

The workspace is Windows; GitHub Actions performs the actual iOS device build on macOS. CI compiles both the device and simulator targets and captures Home in light/dark mode. Keychain, the share sheet, and authenticated artifact downloads still need verification on a physical device.

## Connect GitHub

Public release browsing and downloads work without signing in. **Sign in with GitHub** in Settings uses the public login service; activation still requires the OAuth credentials in [Backend/README.md](Backend/README.md). Under Advanced, you can connect a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) limited to the repositories you need, with **Actions: Read-only** and **Contents: Read-only**. GitHub may require organization approval. Enter the token in the app; never commit it to this repository. With manual sign-in, GitHub Inbox requires a [classic token](https://github.com/settings/tokens/new) with `notifications` (or `repo` for private repositories); GitHub does not support fine-grained tokens for the [notifications API](https://docs.github.com/en/rest/activity/notifications).

For collaboration with a fine-grained token, add **Issues: Read and write** for issue creation, **Pull requests: Read and write** for reviews, and **Contents: Read and write** for merging and branch creation. Your account also needs the corresponding repository permission. GitHub enforces its own branch rules. Watch/unwatch uses GitHub subscriptions; Inbox still requires OAuth or a classic token as noted above.

After sign-in, the token is validated with `/user`, stored using a device-only Keychain accessibility class, and sent only to `api.github.com`. API responses use ephemeral sessions. Redirects allow HTTPS GitHub storage endpoints and strip authorization before changing hosts. Downloaded files are stored locally with iOS file protection and excluded from backup. Disconnecting cancels downloads and clears loaded account data; watched repository names and deliberately downloaded files remain on the device.

## Check the code

The app compiles the same `Sources/ForgeCore` files that the dependency-free Swift package tests exercise:

```sh
swift test
```

Optional live check using public GitHub data (downloads a small checksum file):

```sh
mkdir -p .build
swiftc -parse-as-library Sources/ForgeCore/*.swift Scripts/CheckAPI.swift -o .build/check-api
.build/check-api
```

On a Mac, verify the actual iOS target separately:

```sh
xcodebuild -project Forge.xcodeproj -scheme Forge \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Device checks: add/remove a repository; connect/disconnect a token; inspect a failed run; download a real Actions artifact; save both an artifact and a release file to Files; cancel/retry a download; relaunch and share the saved file; check VoiceOver and large text sizes.

Verified on 2026-09-23 with Swift 6.0.3 in the existing Linux container:

- **45 core tests passed**, including native Profile routes, authenticated own-repository pagination, profile/star/organization data, Actions pagination without Favorites, notification read-state writes and branch creation/validation, issue/review writes, merge commit checks and rejected merges, review resolution permissions, subscriptions, organization Discussion destinations, native URL routing, immutable code previews, GraphQL error handling and pagination, login setup errors, token boundaries, binary content negotiation, expired artifacts, safe filenames, OAuth callback validation, raw repository files, repository search, notification destinations, pagination, date decoding, run states, HTTP failures, and repository validation.
- The app/core Swift files passed Swift syntax parsing; the core and live-check executable compiled successfully.
- The live checks decoded 30 public workflow runs, 22 release assets with counts, 4 jobs, 4 artifacts, and 27 repository entries from `cli/cli`. They downloaded the 1,971-byte `gh_2.101.0_checksums.txt` and the 6,262-byte repository `README.md` through the app's API client.
- Xcode object IDs, source references, scheme XML, property lists, asset JSON, and the app icon passed structural checks.
- **Also verified in [build 12, attempt 2](https://github.com/rdiol12/forge/actions/runs/35889593880):** all 30 Swift tests and 2 backend tests on macOS, device/simulator builds with Xcode 26.3, and native profile/repository screenshots. The first attempt timed out booting the simulator before the app launched; the fresh runner completed successfully. The Actions screenshot verified its native rate-limit error state because anonymous GitHub access was exhausted; populated Actions and artifact data were checked separately with authenticated real API requests. The published [0.6.0 IPA](https://github.com/rdiol12/forge/releases/tag/build-12-2) passed ZIP integrity, SHA-256, version, unsigned-package, and iOS device platform checks and matched its Actions artifact byte for byte. The 1,120,054-byte IPA has SHA-256 `b01f8421c6b5714bdb872898e854d116c3bdfa2a3d1a7fafca9ffdd268dd755f`.
- **Not yet verified:** complete browser OAuth sign-in (registration credentials are still missing), device interaction flows, native download progress/cancellation/persistence, Keychain, sharing, and token-authenticated downloads on a physical iPhone. The same core API client has downloaded the private Forge Actions artifact and release IPA successfully from the Linux check.

## Current limits

- Monitoring: latest 30 runs and 20 releases per watched repository, labeled in the interface. Detail screens page through all assets, artifacts, and jobs on demand.
- Repository files: switch branches with commit-pinned listings, with up to 1,000 entries per folder. Native code reading supports UTF-8 text up to 1 MiB; binary/larger files use Download and Quick Look. Code previews use the immutable blob revision from the listing.
- Native collaboration supports issue creation, issue/PR/Discussion watching, PR reviews, review-thread resolution, and direct merging. Merge queues/auto-merge and editing merge conflicts are not implemented. Markdown images/tables are not fully rendered. GitHub search caps results at 1,000 and pull-request files at 3,000; large/binary diff patches may be omitted.
- Discussions require an API token because GitHub exposes them through authenticated GraphQL. A browser website session cannot supply this API connection.
- Refresh on app activation or pull to refresh. No push notifications or background monitoring.
- Release assets, Actions artifacts, repository ZIPs and log archives use iOS background transfers after a safe redirect handshake. iOS controls timing; force-quitting may interrupt transfers. Direct API blob downloads need Forge open. Failed/interrupted entries persist and Try again starts a fresh request; byte-range resume is not implemented.
- GitHub.com only, one account at a time. Enterprise hosts are not implemented. Standard browser OAuth needs the GitHub app registration and hosted backend configured; manual tokens remain available under Advanced.
- Native log previews are limited to 2 MiB; full logs remain downloadable. Syntax colors use a lexical highlighter rather than a compiler. Markdown renders headings, lists, quotes and fenced code; embedded HTML stays text.
- Repository source ZIPs are available from Code for the selected branch/commit. GitHub does not expose download counts for these archives.
- This is an initial implementation, not an App Store submission. Before shipping, validate the iOS build/device flows and finish production onboarding and distribution.

GitHub Mobile already includes many collaboration features. The product hypothesis here is quicker access to build outputs and release download statistics, not complete feature parity or a pixel-for-pixel copy of every official screen. The shell follows the current [App Store screenshots](https://apps.apple.com/us/app/github/id1477376905); Issues, Discussions, pull requests, code, profiles, repository lists, and organizations have native screens. Copilot is a Home shortcut rather than a separate floating control. [Official GitHub Mobile](https://github.com/mobile)

Public feedback and implementation status: [FEEDBACK.md](FEEDBACK.md).

Native API live check (optionally pass --authenticated and a developer token on stdin; never commit tokens):

```sh
swiftc -parse-as-library Sources/ForgeCore/*.swift Scripts/CheckNative.swift -o .build/check-native
.build/check-native
```

On 2026-09-23 the authenticated live check read cli/cli code, 30 issues, 30 pull requests, 26 changed files, 7 reviews, 11 review comments, and community Discussions with cursor pagination, comments, and replies. iPhone UI verification is performed separately in CI.

The authenticated native check also reads watch state, PR merge settings, review threads, comments, and viewer permissions. Mutations are tested with mocked responses: the check never creates issues, submits reviews, changes subscriptions, marks notifications read, creates branches, or merges a real PR. Add `--forge-build` to verify the private Forge workflow, test steps, artifact download, release IPA, and checksum using the app's API client; files are saved under ignored `dist/api-check-build-<number>/`.

The `--account` live check verified the native profile, 15 owned repositories including private Forge, starred repositories, visible organization memberships, and private workflow runs/jobs/artifacts without Favorites state. It reads credentials from stdin only and makes no writes to GitHub.

## Additional permissions and API references

Actions write is needed for re-runs/cancellation; Issues write for issue changes; Pull requests write for reviews/line comments; Discussions write for replies; Contents write for README commits and release changes; Administration write plus repository admin access for visibility changes. Read-only tokens continue to browse.

References: [GitHub Mobile UI](https://github.com/mobile), [workflow jobs/logs](https://docs.github.com/en/rest/actions/workflow-jobs), [PR line comments](https://docs.github.com/en/rest/pulls/comments), [issue edits](https://docs.github.com/en/rest/issues/issues), [file commits](https://docs.github.com/en/rest/repos/contents), [releases](https://docs.github.com/en/rest/releases/releases), [visibility](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility), [background URLSession](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

