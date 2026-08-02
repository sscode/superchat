# Third-party notices

Superchat includes and builds on third-party software and assets. Those
components remain under their original licences.

## Vercel Labs Native SDK

- Project: https://github.com/vercel-labs/native
- Version: `@native-sdk/cli` 0.5.1
- Licence: Apache License 2.0
- Licence text: `LICENSES/Apache-2.0.txt`

Superchat applies build-time changes to Native SDK through
`scripts/patch-native-sdk.mjs`. The patch raises a compile-time quota, adjusts
focused text-entry shortcut dispatch, and changes programmatic scroll clamping.
These changes are identified in the patch script and are not represented as
upstream Native SDK behavior.

## Geist and Geist Mono

- Project: https://github.com/vercel/geist-font
- Copyright: Copyright (c) 2023 Vercel, in collaboration with basement.studio
- Licence: SIL Open Font License 1.1
- Licence text: `LICENSES/OFL-1.1.txt`

Native SDK embeds Geist font data in the compiled application.

## System libraries

Superchat links to SQLite and Apple system frameworks supplied by macOS. These
are not distributed as source components in this repository.
