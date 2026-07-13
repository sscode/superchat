# Superchat

**A fast, local-first AI chat workspace for macOS.**

Superchat keeps projects, conversations, drafts, and model choices on your Mac while using [OpenRouter](https://openrouter.ai/) to talk to the models you choose. It is built with the [Vercel Labs Native SDK](https://github.com/vercel-labs/native), Zig, and a GPU-rendered native interface—there is no web app or WebView hiding underneath.

> Superchat is an early prototype. OpenRouter is ready to use; accounts, cloud sync, subscription-based providers, packaging, and automatic updates are still planned.

## What you can do

- Organize conversations into projects.
- Switch models per chat, including a custom OpenRouter model slug.
- Stream several responses at once and move between chats while they finish.
- Fork an assistant response into one or several new chats, each with a different model.
- Copy complete responses or select and copy text from a rendered paragraph.
- Rename, archive, restore, and permanently delete projects and chats.
- Navigate the entire app with keyboard shortcuts.
- Keep chat data in a local SQLite database and your API key in macOS Keychain.

## Quick start

### What you need

- A Mac.
- [Node.js](https://nodejs.org/) and npm.
- An [OpenRouter API key](https://openrouter.ai/keys).

### 1. Install the project

```bash
git clone https://github.com/sscode/superchat.git
cd superchat
npm install
```

The first Native SDK command downloads its pinned Zig toolchain automatically.

### 2. Launch the app

```bash
npm run dev
```

Development mode skips onboarding so you can get straight into the app. To experience the first-run flow instead, use:

```bash
npm run dev:onboarding
```

### 3. Connect OpenRouter

Open **Settings** with `⌘,`, choose **Add API key**, and paste your OpenRouter key. Superchat stores it in macOS Keychain—not in the chat database or source tree.

Choose a model with `⌘K`, write a message, and press `⌘↩` to send.

## A typical workflow

1. Create a project with `⌘⇧N` and a chat with `⌘N`.
2. Open the model picker with `⌘K`. Choose Auto, a suggested model, or enter any OpenRouter model slug.
3. Send a message with `⌘↩`.
4. Move to another chat while the answer streams; the original request continues in the background.
5. On an assistant response, choose **Copy** or **Fork**. Forking can create several model-specific chats at once and optionally start each with the same follow-up message.

## Keyboard shortcuts

Superchat is designed to be usable without reaching for the mouse. The same reference is available inside **Settings → Shortcuts**.

| Action | Shortcut |
| --- | --- |
| New chat | `⌘N` |
| New project | `⌘⇧N` |
| Previous / next chat | `⌘[` / `⌘]` |
| Previous / next project | `⌘⌥↑` / `⌘⌥↓` |
| Focus composer | `⌘L` |
| Send message | `⌘↩` |
| Choose model | `⌘K` |
| Fork latest response | `⌘⇧F` |
| Copy latest response | `⌘⇧C` |
| Rename chat | `⌘⇧R` |
| Rename project | `⌘⌥R` |
| Archive chat | `⌘⇧E` |
| Archive project | `⌘⌥E` |
| Open archive | `⌘⇧H` |
| Clear current chat | `⌘⇧⌫` |
| Open settings | `⌘,` |
| Open account | `⌘⇧A` |
| Close the current panel | `Esc` |

## Local data and privacy

Superchat does not require an account or run a local database server.

- Projects, chats, messages, drafts, model choices, and archive state are stored in SQLite at `~/Library/Application Support/superchat/superchat.sqlite3`.
- Your OpenRouter API key is stored separately in macOS Keychain.
- Requests and the conversation context needed to answer them are sent to OpenRouter and the selected model provider. Check their privacy policies before sending sensitive information.
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

You can also provide a key to a development process without saving it through the UI:

```bash
OPENROUTER_API_KEY="your-key" npm run dev
```

Avoid placing real credentials in `.env.example` or committing them to Git.

### Project map

| Path | What lives there |
| --- | --- |
| `src/main.zig` | Application state, actions, OpenRouter requests, and SSE streaming |
| `src/storage.zig` | SQLite schema, migrations, loading, and persistence |
| `src/app.native` | Native UI, layout, styling, and keyboard handling |
| `src/tests.zig` | Unit and integration-style state tests |
| `app.zon` | App identity, window configuration, menu commands, and shortcuts |
| `build.zig` | Zig build and native dependencies |
| `AUTH_PLAN.md` | Proposed optional authentication and sync architecture |

## Current status and limits

The intentionally small first version has a few boundaries worth knowing:

- macOS is the only supported platform.
- OpenRouter API keys are the only working provider connection. Claude and ChatGPT subscription connections appear as planned options but are disabled.
- Account screens are local UI scaffolding; authentication and sync are not implemented. See [AUTH_PLAN.md](AUTH_PLAN.md) for the proposed direction.
- Each chat currently retains its latest 12 messages, with up to 5,000 bytes per message.
- The workspace currently supports up to 8 projects and 24 total chats; archived items count toward those limits until deleted.
- Release packaging, code signing, GitHub distribution, and update checks are not implemented yet.

These constraints keep the prototype easy to understand while its storage and provider boundaries settle.

## Why Native SDK?

This repository is also a practical test of Vercel Labs' Native SDK: the interface is declared in `.native`, application behavior is written in Zig, HTTP runs through Native effects, and SQLite is embedded in-process. The result is a small desktop app with immediate startup, low overhead, and no frontend framework runtime.
