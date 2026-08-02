# Contributing to Superchat

Thanks for helping make Superchat faster, clearer, and more reliable.

## Before you start

- Search existing issues and pull requests.
- Open an issue before beginning a large feature or architectural change.
- Keep contributions focused on the local-first macOS scope in `ROADMAP.md`.
- Follow `CODE_OF_CONDUCT.md`.
- Report vulnerabilities through `SECURITY.md`, not a public issue.

## Set up locally

You need macOS, Node.js 22 or newer, npm, and Xcode Command Line Tools.

```bash
npm ci
npm run dev
```

Use `npm run dev:onboarding` when your change affects first-run setup.
Use `npm run dev:worktree` when running more than one checkout. Development
profiles use separate application-data directories and never share the release
database.

## Development workflow

Create a topic branch, make focused commits, and add tests for behavior changes.
Preserve keyboard access and verify affected layouts at the minimum 720 × 480
window size.

Before opening a pull request, run:

```bash
npm run check
npm test
npm run build
```

For packaging changes, also run:

```bash
npm run package:macos
```

Development and ad-hoc packages do not persist provider credentials in the
release application's Keychain item.

## Privacy and repository hygiene

Never commit API keys, provider tokens, chat databases, exports, private
prompts, user documents, notarisation credentials, or other personal data.

Screenshots must be deliberately staged and cropped to the application. Do not
include the macOS desktop, menu bar, Dock, personal file names, other apps, or
private conversations. Generated build output and local UI-review artifacts do
not belong in the repository.

## Commit sign-off

Superchat uses the Developer Certificate of Origin in `DCO.md`. Sign off every
commit:

```bash
git commit -s
```

The sign-off certifies that you have the right to submit the contribution under
the project's licence. It is not a copyright assignment. CI checks every
pull-request commit for this sign-off.

## Licence

Except where a file or third-party notice says otherwise, contributions are
accepted under `AGPL-3.0-only`, the same licence as the project.

Do not add dependencies, fonts, icons, copied code, or generated assets without
documenting their source and licence in `THIRD_PARTY_NOTICES.md`. Changes to
Native SDK's build-time patch must remain clearly identified.

## Pull requests

Explain the user-visible outcome, implementation boundaries, and verification
performed. Complete the pull-request checklist and respond to review feedback.
Maintainers may ask for a change to be split when it mixes unrelated concerns.
