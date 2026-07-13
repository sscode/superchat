# Contributing to Superchat

Thanks for helping make Superchat faster, clearer, and more reliable.

## Set up locally

You need macOS, Node.js 22 or newer, npm, and Xcode Command Line Tools.

```bash
npm install
npm run dev
```

Use `npm run dev:onboarding` when your change affects first-run setup.

## Before opening a pull request

Run the complete local quality gate:

```bash
npm run check
npm test
npm run build
```

Keep pull requests focused and explain the user-visible outcome. Add or update tests for behavior changes, preserve keyboard access, and verify layouts at the minimum 720 × 480 window size. Never commit API keys, provider tokens, chat databases, or other private user data.

For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
