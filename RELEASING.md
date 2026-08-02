# Release process

This checklist applies to official Superchat macOS releases.

Versions before `v0.1.3` were released under the MIT licence. Starting with
`v0.1.3`, Superchat is licensed under AGPL-3.0-only.

## One-time public launch

- Review the complete Git history for credentials, personal data, and
  repository-only design artifacts. Publish from a clean root when the existing
  history is not suitable for permanent public access.
- Ensure every previously published binary either carries the notices required
  by its release licence or remains unpublished.
- Change repository visibility only after the history and old releases pass
  review.
- Enable GitHub private vulnerability reporting and secret scanning after the
  repository is public.
- Require the `DCO sign-off` and both macOS CI checks on the default branch.
- Protect the `release` environment and its `v*` tag deployment policy. Add a
  required reviewer when the repository plan supports it.

## Repository configuration

Configure these GitHub Actions secrets:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_APP_PASSWORD`
- `APPLE_TEAM_ID`

Keep signing and notarisation credentials out of local files, workflow YAML,
issues, logs, and release notes.

## Cut a release

1. Update the version in `app.zon`, `package.json`, `package-lock.json`,
   `build.zig`, `build.zig.zon`, and `src/mcp.zig`.
2. Update user-facing documentation and release notes.
3. Run:

   ```bash
   npm ci
   npm run check
   npm test
   npm run build
   npm run package:macos
   ```

4. Confirm the local DMG is universal, its checksum verifies, and its app
   bundle contains `Licenses`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, `PRIVACY.md`,
   and `SOURCE.txt`.
5. Commit with DCO sign-off and create a signed tag matching the package
   version, such as `v0.2.0`.
6. Push the commit and tag. The release workflow builds from the tag, signs and
   notarises the app, regenerates the post-stapling checksum, creates build
   provenance, and publishes the GitHub release.
7. Download the published assets and verify the checksum, notarisation, source
   link, and licence files before announcing the release.

Do not reuse a version or move a published tag. If a release is faulty, publish
a new patch version.
