# Authentication plan

## Goal

Add identity and eventual cross-device sync without making an account a requirement for using Superchat. A user must always be able to open the app, add their own OpenRouter key, and chat locally.

No Superchat account UI is shipped today. The app does not collect an email, contact a Superchat backend, create an identity, or sync data. Provider sign-in is separate: OpenRouter keys remain device-local, while Codex authentication stays in the official provider app or CLI.

## Current constraints

- The app is a native Zig application using Native SDK, not a browser shell.
- Projects, threads, messages, drafts, model choices, archive timestamps, and attachment metadata persist in a local SQLite database. Attachment contents remain in their original files and are not copied into the database.
- The OpenRouter API key is stored in the operating system credential store. Codex authentication remains owned by the official client; Superchat only launches its status, login, and chat commands.
- Network access is permitted for OpenRouter, and system-browser navigation is
  restricted to an exact allowlist of project and release URLs.
- There is no backend or deep-link handler yet; SQLite is strictly device-local.

The durable local model now exists, so the next prerequisite for sync is stable UUIDs and change metadata rather than authentication plumbing inside the chat path.

## Recommended product model

Superchat should be **local-first with an optional account**:

1. Local-only users get the complete chat experience on one Mac.
2. Signing in adds backup and multi-device sync; it does not unlock basic chat.
3. The user's OpenRouter key remains device-local by default and is never uploaded with chat data.
4. Signing out removes account tokens but does not delete local projects or chats.
5. Deleting an account is a separate, explicit destructive operation with a clear choice about local data.

This keeps auth out of the critical path and gives the account a concrete benefit rather than presenting it as ceremony.

## Proposed sign-in flow

Use a hosted authorization page in the system browser with OAuth 2.0 Authorization Code + PKCE. Offer Sign in with Apple and GitHub first, with email code as a fallback. Do not collect or store passwords in the desktop app.

Expected flow:

1. The user selects **Sign in** in Superchat.
2. The app creates a PKCE verifier, challenge, nonce, and short-lived state value.
3. The system browser opens the hosted authorization page.
4. The provider redirects to an app callback after authorization.
5. Superchat validates the state and exchanges the one-time code through the auth backend.
6. The access token stays in memory; the refresh token is stored in Keychain.
7. The account UI changes to the authenticated identity and sync starts independently.

The exact callback mechanism needs a Native SDK spike. Preferred order:

1. A registered `superchat://auth/callback` URL scheme.
2. A short-lived loopback callback on `127.0.0.1` if custom schemes are not supported cleanly.
3. Email code entry in the native app as a fallback that needs neither mechanism.

## Backend boundary

Authentication requires a small hosted service; GitHub Releases cannot act as an identity backend. Keep the desktop client provider-neutral behind these operations:

```text
POST /v1/auth/code/exchange
POST /v1/auth/refresh
POST /v1/auth/logout
GET  /v1/me
GET  /v1/sync/changes?cursor=...
POST /v1/sync/changes
DELETE /v1/account
```

The service owns Superchat account secrets, session rotation, revocation, rate limiting, and the canonical sync cursor. The app owns local data and the device identifier. OpenRouter credentials and official CLI subscription sessions remain device-local and are not uploaded.

For the first implementation, choose a managed identity provider that supports PKCE, Apple, GitHub, email codes, refresh-token rotation, and account deletion. Hosting and database choices can remain separate. A serverless API plus managed SQL database is sufficient; Cloudflare Workers/D1, Supabase, or a similar stack can all fit this boundary. Make the vendor decision only after the callback spike and sync data model are settled.

## Data and sync prerequisites

Before connecting real auth:

1. Keep projects, threads, messages, drafts, and device settings durable in SQLite. Core workspace records are now persisted; preferences can follow as they become real product settings.
2. Give every syncable record a stable UUID, `created_at`, `updated_at`, and optional `deleted_at`.
3. Separate local device settings from syncable account preferences.
4. Define conflict behavior. Start with last-write-wins for project/thread metadata and append-only message records.
5. Maintain an operation log or change cursor so reconnecting does not require replacing the entire workspace.

Suggested ownership:

| Data | Default location | Sync later? |
| --- | --- | --- |
| OpenRouter API key | Keychain | No |
| Codex session | Official client credential store | No |
| Account refresh token | Keychain | No |
| Account access token | Memory | No |
| Projects and threads | Local database | Yes, when signed in |
| Messages | Local database | Yes, when signed in |
| Drafts | Local database | Optional |
| Hotkeys and appearance | Local settings | Optional |

## Security requirements

- Never put provider client secrets in the desktop binary.
- Use PKCE, state, nonce, one-time authorization codes, and short-lived access tokens.
- Rotate refresh tokens and revoke the token family when reuse is detected.
- Store refresh tokens only in the OS credential store and clear them on sign-out.
- Restrict callback URLs and any newly allowed external origins to an exact allowlist.
- Redact tokens and email addresses from logs and crash reports.
- Rate-limit email codes and code exchanges.
- Provide session/device revocation and account deletion before a broad public launch.
- Decide and document retention, export, and deletion behavior before syncing user content.

## Delivery sequence

### Phase 0 — now

- Keep account UI out of the product until it provides a real, working sync benefit.
- Preserve local-only mode.
- Add no auth dependency and send no account data over the network.

### Phase 1 — durable local workspace

- Maintain the local SQLite database and forward-only schema migrations. **Initial schema complete.**
- Persist projects, threads, messages, drafts, per-thread models, and archive metadata. **Complete.**
- Introduce stable record and device identifiers.

### Phase 2 — identity spike

- Prove system-browser launch and callback handling in Native SDK.
- Integrate one provider in a development environment.
- Store and restore a refresh token through Keychain.
- Add tests for cancellation, expired codes, offline launch, and revoked sessions.

### Phase 3 — production auth

- Add Apple, GitHub, and email-code options.
- Implement token rotation, logout, device/session management, and account deletion.
- Replace the prototype state with a real session state machine: signed out, authorizing, signed in, refreshing, offline, and expired.

### Phase 4 — sync

- Upload/download changes independently of the chat request lifecycle.
- Show sync state without blocking navigation or responses in other threads.
- Add conflict, retry, migration, and recovery tests before enabling sync by default.

## Decisions still needed

- Whether accounts are only for sync or also support subscriptions and team workspaces.
- Whether message content is stored normally server-side or encrypted before upload.
- Which identity provider and database to operate.
- The Native SDK callback mechanism that works reliably in signed production builds.
- Data retention, export, deletion, and regional hosting requirements.

None of these decisions need to block the local chat product today.
