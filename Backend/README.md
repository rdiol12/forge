# GitHub browser sign-in backend

The iPhone uses ASWebAuthenticationSession with S256 PKCE and a random state. This small Cloudflare-compatible Worker exchanges the one-use authorization code using a server-side client secret. It does not store tokens or log request bodies. The token is returned over HTTPS to the iPhone and saved in Keychain. GitHub remains the identity provider; Forge never collects a GitHub password.

GitHub app registration:
- Name: Forge
- Homepage: https://github.com/rdiol12/forge
- Callback: app.forge.github://oauth/callback
- OAuth scopes requested: repo and notifications. The repo scope includes write access because GitHub OAuth does not offer a private-repository read-only scope; Forge currently uses read-only APIs.
- Device flow: disabled. Use the standard authorization-code flow.

Runtime secrets: GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET. Keep the secret on the backend, never in Swift, Info.plist, Git, or an IPA. Missing configuration returns HTTP 503. The public configuration endpoint returns only the client ID. The token endpoint accepts only a code and a PKCE verifier, with a fixed GitHub upstream and callback URL. Responses are no-store; redirects and arbitrary callback destinations are rejected.

The public service is https://forge-github-signin.j239pt2mgegnt9dxw7.chatgpt.site. The deployment checkout is C:/Users/rdiol/dev/ForgeAuth. This directory retains an auditable copy of the Worker and tests with the iOS source. Validate changes with node --test from this directory, then update the deployment checkout and publish the same source using Sites.

The service was published publicly on 2026-09-23. Activation still requires registration credentials in the Sites runtime environment. The root responds with HTTP 200; /oauth/config intentionally responds with HTTP 503 until both credentials are configured. The private app repository and IPA releases remain separate from the login endpoint.
