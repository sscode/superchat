# Superchat

**A fast, local-first AI chat workspace for macOS.**

Superchat keeps projects, conversations, drafts, and model choices on your Mac. Talk through [OpenRouter](https://openrouter.ai/) or your signed-in [Codex CLI](https://developers.openai.com/codex/cli) session. An experimental development-only Claude CLI harness is included for local evaluation. It is built with the [Vercel Labs Native SDK](https://github.com/vercel-labs/native), Zig, and a GPU-rendered native interface—there is no web app or WebView hiding underneath.

> Superchat is an early public beta. OpenRouter and Codex/ChatGPT-plan connections are available; cloud sync and automatic in-app updates are still planned.

## What you can do

- Start chats immediately or organize related conversations into optional projects.
- Use an existing ChatGPT plan through the official local Codex CLI, without giving Superchat its session token.
- Search OpenRouter's live model catalog, favorite useful results, or enter a model slug directly.
- Stream several responses at once and move between chats while they finish.
- Fork an assistant response into one or several new chats, each with a different model.
- Copy complete responses or select and copy text from a rendered paragraph.
- Rename, archive, restore, and permanently delete projects and chats.
- Navigate the entire app with keyboard shortcuts.
- Keep chat data in a local SQLite database and your API key in macOS Keychain.

## Quick start

### Install a release

Download the universal `.dmg` from [GitHub Releases](https://github.com/sscode/superchat/releases), open it, and drag Superchat to Applications. Release builds contain both Apple Silicon and Intel code; users do not need Node.js, npm, or Zig.

On first launch, choose one connection:

- **Codex · ChatGPT plan:** install/sign in to Codex (or the ChatGPT macOS app), then choose **Connect Codex**.
- **Claude (development builds only):** an experimental local CLI adapter is present for evaluation, but is disabled in public release builds pending Anthropic approval.
- **OpenRouter:** paste an [OpenRouter API key](https://openrouter.ai/keys). Superchat verifies it before saving it to macOS Keychain.

The subscription buttons launch the official CLI's browser sign-in. Superchat neither receives nor stores the resulting provider session token.

### Run from source

Contributors need macOS, Node.js 22+, npm, and Xcode Command Line Tools:

```bash
git clone https://github.com/sscode/superchat.git
cd superchat
npm install
```

The first Native SDK command downloads its pinned Zig toolchain automatically.

```bash
npm run dev
```

Development mode skips onboarding so you can get straight into the app. To experience the first-run flow instead, use:

```bash
npm run dev:onboarding
```

Open **Settings** with `⌘,` to connect Codex or OpenRouter. Development builds also expose the experimental Claude adapter. OpenRouter keys are validated and stored in macOS Keychain—not in the chat database or source tree. CLI credentials remain owned by their providers.

Debug and locally packaged ad-hoc builds deliberately keep API keys in memory for the current session instead of reading or writing Keychain. This prevents rebuilt binaries from repeatedly asking for access to the release app's credential. Set `OPENROUTER_API_KEY` when launching a development build if you do not want to paste it again. Keychain persistence is enabled only in consistently Developer-ID-signed release builds.

Choose a model with `⌘K`, write a message, and press `↩` to send. Use `⌘↩` when you want a new line.

## A typical workflow

1. Create a top-level chat with `⌘N`. Projects are optional: create one with `⌘⇧N`, then add chats to it with `⌘⌥N`.
2. Open the model picker with `⌘K`. Choose Codex, search OpenRouter's catalog, choose Auto, or enter a model slug. Development builds also show the experimental Claude adapter.
3. Send a message with `↩`.
4. Move to another chat while the answer streams; the original request continues in the background.
5. On an assistant response, choose **Copy** or **Fork**. Forking can create several model-specific chats at once and optionally start each with the same follow-up message.

## Keyboard shortcuts

Superchat is designed to be usable without reaching for the mouse. The same reference is available inside **Settings → Shortcuts**.

| Action | Shortcut |
| --- | --- |
| New top-level chat | `⌘N` |
| New chat in selected project | `⌘⌥N` |
| New project | `⌘⇧N` |
| Previous / next chat | `⌘[` / `⌘]` |
| Top-level chats | `⌘0` |
| Projects 1–9 | `⌘1` through `⌘9` |
| Chats 1–9 in the current area | `⌥1` through `⌥9` |
| Previous / next project | `⌘⌥↑` / `⌘⌥↓` |
| Focus composer | `⌘L` |
| Send message | `↩` |
| New line in message | `⌘↩` |
| Choose model | `⌘K` |
| OpenRouter Auto | `⌘⇧0` |
| Quick models 1–9 | `⌘⇧1` through `⌘⇧9` |
| Use Codex subscription | `⌘⌥⇧1` |
| Use Claude subscription | `⌘⌥⇧2` |
| Fork latest response | `⌘⇧F` |
| Copy latest response | `⌘⇧C` |
| Rename chat | `⌘⇧R` |
| Rename project | `⌘⌥R` |
| Archive chat | `⌘⇧E` |
| Archive project | `⌘⌥E` |
| Open archive | `⌘⇧H` |
| Clear current chat | `⌘⇧⌫` |
| Load earlier messages | `⌘⌥L` |
| Open settings | `⌘,` |
| Close the current panel | `Esc` |

For dynamic controls—model search results, archive items, fork model choices, and confirmation buttons—use `Tab` / `Shift+Tab` to move and `Enter` or `Space` to activate. The numbered shortcuts cover the first nine visible projects and chats; the previous/next shortcuts cover everything beyond them.

## Local data and privacy

Superchat does not require an account or run a local database server.

- Projects, chats, messages, drafts, model choices, and archive state are stored in SQLite at `~/Library/Application Support/superchat/superchat.sqlite3`.
- Your OpenRouter API key is stored separately in macOS Keychain. Codex and the development-only Claude harness leave authentication in each provider's own CLI credential store.
- Requests and a bounded recent conversation context are sent only through the selected connection. Check provider privacy policies before sending sensitive information.
- There is currently no cloud sync, telemetry service, or remote Superchat backend.

Archived items disappear from the main workspace immediately. You can restore them or choose **Delete forever** from the archive. Anything left archived is permanently removed after 30 days.

## Development

| Command | Purpose |
| --- | --- |
| `npm run dev` | Run with development mode enabled and onboarding skipped |
| `npm run dev:onboarding` | Run the first-time onboarding flow |
| `npm run check` | Run strict compile-time checks |
| `npm test` | Run the test suite |
| `npm run build` | Create a release build |
| `npm run package:macos` | Clean-build a universal, ad-hoc-signed `.app` and `.dmg` |

You can also provide a key to a development process without saving it through the UI:

```bash
OPENROUTER_API_KEY="your-key" npm run dev
```

Avoid placing real credentials in `.env.example` or committing them to Git.

### Project map

| Path | What lives there |
| --- | --- |
| `src/main.zig` | Application state, actions, OpenRouter SSE, and CLI provider harnesses |
| `src/storage.zig` | SQLite schema, migrations, loading, and persistence |
| `src/persistence.zig` | Debounced, background SQLite command queue |
| `src/app.native` | Native UI, layout, styling, and keyboard handling |
| `src/tests.zig` | Unit and integration-style state tests |
| `app.zon` | App identity, window configuration, menu commands, and shortcuts |
| `build.zig` | Zig build and native dependencies |
| `scripts/package-macos.sh` | Reproducible universal macOS packaging |
| `.github/workflows/` | ARM/Intel CI and signed, notarized tag releases |
| `AUTH_PLAN.md` | Proposed optional authentication and sync architecture |

## Current status

The intentionally small first version has a few boundaries worth knowing:

- macOS is the only supported platform.
- Subscription connections require the corresponding official CLI to remain installed and signed in. Codex currently delivers its completed answer as one event; the experimental Claude harness and OpenRouter stream partial text.
- Anthropic's current [authentication guidance](https://code.claude.com/docs/en/legal-and-compliance) does not allow unapproved third-party products to offer Claude.ai login or route Pro/Max credentials. The Claude harness is therefore disabled outside development builds; obtain approval or switch it to user-supplied API authentication before release.
- Authentication and sync are not in the app's critical path. See [AUTH_PLAN.md](AUTH_PLAN.md) for the proposed optional architecture.
- SQLite retains the complete transcript. The UI opens the latest 50 messages and loads earlier pages on demand; provider requests independently use a bounded recent context. Native SDK currently caps CLI-harness prompt input at 4 KiB.
- Projects and chats grow dynamically instead of stopping at prototype-era 8/24 limits. Individual responses have a 64 KiB safety ceiling.
- Tagged GitHub releases build a clean universal app, sign it with Developer ID, submit it for Apple notarization, staple the result, and publish the `.dmg` to GitHub Releases.
- Automatic in-app update checks are not implemented yet; GitHub Releases is the distribution source for the beta.

Before enabling the release workflow, configure the repository secrets documented below.

## Publishing a macOS release

The release workflow runs for tags matching `v*`. Add these GitHub Actions secrets:

- `MACOS_CERTIFICATE_P12` — base64-encoded Developer ID Application certificate.
- `MACOS_CERTIFICATE_PASSWORD` and `MACOS_SIGNING_IDENTITY`.
- `APPLE_ID`, `APPLE_APP_PASSWORD`, and `APPLE_TEAM_ID` for notarization.

Then update the version in `app.zon` and `package.json`, create a tag such as `v0.2.0`, and push it. GitHub hosts the resulting release and DMG; no Cloudflare service is required.

## Why Native SDK?

This repository is also a practical test of Vercel Labs' Native SDK: the interface is declared in `.native`, application behavior is written in Zig, HTTP runs through Native effects, and SQLite is embedded in-process. The result is a small desktop app with immediate startup, low overhead, and no frontend framework runtime.
