# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's
**Security → Report a vulnerability** flow:

https://github.com/sscode/superchat/security/advisories/new

Include the affected version, reproduction steps, expected impact, and any
suggested mitigation. Do not access data that is not your own while
investigating. Please allow a reasonable period for acknowledgement and
remediation before public disclosure.

If private reporting is temporarily unavailable, contact the maintainer through
their GitHub profile without including exploit details and request a private
channel.

## Supported versions

Superchat is an early beta. Security fixes target the latest published release
and the current `main` branch.

## Security boundaries

- OpenRouter keys use macOS Keychain in consistently signed release builds.
- Codex sessions remain owned by the official local client.
- Development and ad-hoc builds keep OpenRouter keys in process memory.
- Attachments are read only after the user drops or selects them.
- SQLite stores attachment metadata and selected paths, not message attachment
  contents.
- Temporary OpenRouter request files are randomly named, restricted to the
  current user, and removed when the request process exits.
- Local MCP servers run with the current macOS user's permissions. Only install
  and configure servers you trust.

Reports involving credential exposure, unexpected file access, command
execution, unsafe backup import, update redirection, or sandbox escape are
especially important.
