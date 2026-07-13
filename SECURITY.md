# Security policy

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's **Security → Report a vulnerability** flow on the Superchat repository so details can be reviewed privately.

Include the affected version, reproduction steps, expected impact, and any suggested mitigation. Please avoid accessing data that is not your own while investigating.

## Supported versions

Superchat is currently an early beta. Security fixes target the latest published release and the current `main` branch.

Provider credentials are intentionally excluded from the chat database: OpenRouter keys use macOS Keychain in consistently signed release builds, and CLI sessions remain owned by their provider. If you discover behavior that exposes or persists credentials elsewhere, report it privately as a security issue.

Attachments are read only after the user drops or selects them. SQLite stores attachment metadata and the selected local path, not file contents. Attachment-bearing OpenRouter requests use a randomly named temporary file, restrict it to the current user, and remove it when the request process exits.
