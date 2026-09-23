# Forge

A native SwiftUI GitHub companion focused on **Actions, releases, and downloading their files**. Working name: Forge. Requires iOS 17 or later; no third-party iOS runtime dependencies, analytics, or AI service. Standard browser sign-in uses a small OAuth exchange backend.

## Implemented

- Browser sign-in with GitHub using Apple AuthenticationServices, PKCE, state validation, and Keychain. Activation requires the OAuth registration described in Backend/README.md.
- Browse repository folders and download individual files, with native Quick Look previews and Save to Files.
- Hide the Copilot shortcut in Settings; Profile always stays in the tab bar.
- GitHub-style Home, Inbox, Explore, and Profile tabs with native iOS navigation, grouped lists, repository avatars, blue accents, and GitHub's MIT-licensed Octicons.
- Favorite public or token-accessible private repositories; old watched repositories automatically appear in Favorites.
- Open Actions, Releases, and Downloads from Home shortcuts and individual favorite repositories.
- Search real GitHub repositories, page through results, and add them to Favorites.
- Browse real GitHub Inbox notifications with All/Unread filters and pagination (classic token required).
- Issues, pull requests, discussions, organizations, full profiles, and Copilot open GitHub in the native Safari sheet. The browser uses its own GitHub sign-in session.
- See recent Actions runs across repositories, filter failures/active runs, and search by repository, title, or branch.
- Inspect the current run attempt, jobs, and steps; open full job logs on GitHub.
- List Actions artifacts, see their size/expiry, and download available artifacts as ZIPs.
- Follow a release inbox that remembers which releases you have opened.
- See **GitHub's exact per-file release download counts**, with a total for the assets loaded.
- Download release assets, including private ones when your token permits it.
- Track download progress, cancel, retry, and use the native share sheet to **Save to Files**.
- Keep completed downloads in the app's local library, accessible offline and through Files → On My iPhone → Forge → Downloads.

The app starts empty and uses real GitHub data. There are no fabricated metrics or demo downloads.

## Download counts: the distinction that matters

| File type | Download | GitHub download count |
| --- | --- | --- |
| Uploaded release asset | Yes; public assets work without a token | Yes, `download_count` per file |
| Actions build artifact | Yes; token with Actions read access required | **Not exposed by GitHub** |

Counts are cumulative download events, not unique users. Forge does not invent Actions counts or substitute its own local downloads for GitHub totals. Expired artifacts cannot be recovered through this API.

Sources: [Release assets](https://docs.github.com/en/rest/releases/assets), [Actions artifacts](https://docs.github.com/en/rest/actions/artifacts).

## Run on an iPhone or simulator

### Download a CI build

The private [forge-ios repository](https://github.com/rdiol12/forge-ios) builds on GitHub's macOS runners. Download `Forge-unsigned.ipa` from [Releases](https://github.com/rdiol12/forge-ios/releases), then sign it with your sideloading tool before installing. You must have access to the private repository to download its releases.

[Build and publish IPA](https://github.com/rdiol12/forge-ios/actions/workflows/ios.yml) runs on pushes to `main`, version tags (`v*`), and manual **Run workflow** requests. Documentation-only branch pushes are skipped. Each run:

1. Runs the shared Swift tests.
2. Builds the Release iOS device target with Xcode 26.3 and signing disabled. Native Liquid Glass navigation is available on iOS 26; earlier systems use their native appearance.
3. Builds and launches an iPhone simulator and saves light/dark Home screenshots as a workflow artifact. The screenshot simulator has four public favorite repositories; installed IPAs still start empty.
4. Packages the app as `Payload/Forge.app` inside an IPA and checks its ZIP integrity and SHA-256 checksum.
5. Uploads the IPA/checksum as an Actions artifact and publishes them as a private GitHub release.

Branch/manual runs create prereleases named `build-<run>-<attempt>`. Version tags create normal releases. Existing release tags are never overwritten; choose a new version tag for another published version. A failed upload may leave an unpublished draft to remove before retrying that version tag. Build logs are retained on failure.

No Apple credentials or repository secrets are needed. The workflow uses GitHub's temporary token with repository contents permission. This is an **unsigned** device build for later signing, not an App Store/TestFlight upload or an immediately installable IPA. GitHub-hosted runner usage is charged against the account's Actions allowance.

### Build locally

1. On a Mac with **Xcode 26.3 or newer**, open `Forge.xcodeproj`.
2. Select the **Forge** scheme and an iPhone simulator, then Run.
3. For a physical iPhone, choose your Apple development team in Signing & Capabilities and change `app.forge.github` to your own unique bundle identifier.
4. Tap **+** and add a repository as `owner/name`, such as `cli/cli`.
5. Open a release, tap **Download**, then **Save to Files or share**. Actions artifacts are under the individual run.

The workspace is Windows; GitHub Actions performs the actual iOS device build on macOS. CI compiles both the device and simulator targets and captures Home in light/dark mode. Keychain, the share sheet, and authenticated artifact downloads still need verification on a physical device.

## Connect GitHub

Public release browsing and downloads work without signing in. In Settings, connect a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) limited to the repositories you need, with **Actions: Read-only** and **Contents: Read-only**. GitHub may require organization approval. Enter the token in the app; never commit it to this repository. GitHub Inbox requires a [classic token](https://github.com/settings/tokens/new) with `notifications` (or `repo` for private repositories); GitHub does not support fine-grained tokens for the [notifications API](https://docs.github.com/en/rest/activity/notifications).

The token is validated with `/user`, stored using a device-only Keychain accessibility class, and sent only to `api.github.com`. API responses use ephemeral sessions. Redirects allow HTTPS GitHub storage endpoints and strip authorization before changing hosts. Downloaded files are stored locally with iOS file protection and excluded from backup. Disconnecting cancels downloads and clears loaded account data; watched repository names and deliberately downloaded files remain on the device.

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

- **15 core tests passed**, including token boundaries, binary content negotiation, expired artifacts, safe filenames, OAuth callback validation, raw repository files, repository search, notification destinations, pagination, date decoding, run states, HTTP failures, and repository validation.
- All 15 app/core Swift files passed Swift syntax parsing; the core and live-check executable compiled successfully.
- The live check decoded 30 public workflow runs, 22 release assets with counts, 4 jobs, and 4 artifacts from `cli/cli`; it downloaded the 1,971-byte `gh_2.101.0_checksums.txt` through the app's API client and redirect policy.
- Xcode object IDs, source references, scheme XML, property lists, asset JSON, and the app icon passed structural checks.
- **Also verified in GitHub Actions:** all 11 tests on macOS, the complete Release iOS device build with Xcode 16.4, and IPA packaging/checksum validation. The binary targets iOS devices with iOS 17 as its minimum version.
- **Not yet verified:** device interaction flows, native download progress/cancellation/persistence, Keychain, sharing, and token-authenticated artifact/private-repository downloads.

## Current limits

- Monitoring: latest 30 runs and 20 releases per watched repository, labeled in the interface. Detail screens page through all assets, artifacts, and jobs on demand.
- Refresh on app activation or pull to refresh. No push notifications or background monitoring.
- Downloads run in the foreground; keep Forge open until they finish. No resumable or background transfers yet.
- GitHub.com only, one account at a time. Enterprise hosts are not implemented. Standard browser OAuth needs the GitHub app registration and hosted backend configured; manual tokens remain available under Advanced.
- The first version displays release notes as selectable text and opens full logs on GitHub.
- Source-code archives, which have no release-asset download count, remain available through the release's GitHub link.
- This is an initial implementation, not an App Store submission. Before shipping, validate the iOS build/device flows and finish production onboarding and distribution.

GitHub Mobile already includes many collaboration features. The product hypothesis here is quicker access to build outputs and release download statistics, not complete feature parity or a pixel-for-pixel copy of every official screen. The shell follows the current [App Store screenshots](https://apps.apple.com/us/app/github/id1477376905); collaboration detail pages currently open the web interface. Copilot is a Home shortcut rather than a separate floating control. [Official GitHub Mobile](https://github.com/mobile)

Public feedback and implementation status: [FEEDBACK.md](FEEDBACK.md).
