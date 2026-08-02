# Superchat privacy notice

Effective: 26 July 2026

Superchat is a local-first macOS application. The Superchat project does not
operate an account service, analytics service, telemetry endpoint, or cloud
database.

## Data stored on your Mac

Superchat stores projects, chats, messages, drafts, model choices, response
statistics, prompt snippets, MCP server commands, archive state, project
knowledge, and preferences in:

```text
~/Library/Application Support/superchat/superchat.sqlite3
```

OpenRouter API keys are stored in macOS Keychain in consistently signed release
builds. Codex authentication remains in the credential store managed by the
official Codex CLI or ChatGPT application. Development and ad-hoc builds keep
OpenRouter keys in memory for the current process instead of using the release
application's Keychain item. Development and ad-hoc builds also use a separate
application data directory so local testing does not read or modify release
chats.

Message attachment metadata includes the selected file's name, type, and local
path. Attachment contents are not copied into the chat database. Text files
explicitly added as project knowledge are copied into the local database.

## Data sent to model providers

When you send a message, Superchat sends the prompt, a bounded portion of recent
conversation history, applicable project instructions and knowledge, and
supported attachments to the provider you selected:

- OpenRouter, when you use an OpenRouter model.
- OpenAI through the locally installed Codex CLI, when you use Codex.

Those providers process data under their own terms and privacy policies.
Superchat does not proxy these requests through a Superchat-operated server.
Do not send sensitive information unless you are comfortable with the selected
provider receiving it.

For larger OpenRouter requests, Superchat creates a randomly named temporary
file readable only by the current user and removes it when the request process
ends.

## Local MCP servers

MCP servers you configure run as local processes with your macOS user
permissions. Superchat stores their names and commands locally. A tool call runs
only after you explicitly select it, and its result is inserted into the draft
for review. Each server may have its own data-handling behavior.

## Network requests made by Superchat

Depending on the features you use, Superchat connects directly to:

- OpenRouter API endpoints for key validation, model discovery, and responses.
- GitHub's public Releases API to check for application updates.
- OpenAI endpoints indirectly through the official local Codex client.

Superchat does not add its own tracking identifier to these requests. Network
operators and providers may still receive ordinary connection data such as an
IP address and request metadata.

## Exports, backups, and deletion

Markdown exports contain the selected chat. JSON workspace archives contain
projects, chats, messages, attachment metadata, response statistics, prompt
snippets, and MCP server names. They deliberately omit absolute attachment paths,
MCP commands, and credentials. Diagnostic exports contain only app/runtime
metadata and aggregate database counts; they omit messages, drafts, file paths,
commands, and credentials. Review every exported file before sharing it because
workspace archives still contain conversation and project-knowledge content.

You can permanently delete chats and projects from the archive. Archived data
that is not restored is deleted automatically after 30 days. Removing the
application does not automatically remove its database or Keychain item.

## Changes and contact

Material changes to this notice will be documented in the repository and
release notes. Privacy questions may be opened as a GitHub discussion or issue
provided they contain no sensitive information. Report sensitive concerns
privately through the repository's security reporting flow.
