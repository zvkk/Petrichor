# Crate Mac skin — 14 October 2026

User approved the visual mockup and requested implementation as a skin over the
current app. Keep navigation, panel sizing, density, commands and music workflows.

## Scope

1. White paper, ink text, neutral selection, pale controls and fine dividers.
2. System type in authored case; lighter album labels and metadata.
3. Original-colour artwork with 2pt corners and no decorative drop shadows.
4. Outlined play/pause, neutral transport and outlined seek thumb.
5. Keep existing Appearance options; use Light and no artwork tint by default.

The browser mockup's rearranged sidebar and alternative player panel are design
explorations, not implementation requirements. Retain the actual Mac toolbar,
sidebar widths, native tables, existing queue/lyrics panels and 110pt bottom player.

## Progress

- [x] Verify installed identity and source: Crate Mac, org.Petrichor.zak.debug,
  starting at 1180d9f in the crate-dropbox-sync worktree.
- [x] Apply presentation changes.
- [x] Build and review the diff for workflow changes.
- [x] Deliver the signed app with a recoverable previous app bundle.

Do not change library databases, provider configuration, audio, sync, stable app
identity, sorting, selection, drag/drop, search or keyboard commands.

## Verification and delivery

Native Debug build passed with the existing Crate Mac display name and
`org.Petrichor.zak.debug` identity. `codesign --verify --deep --strict` passed for
the build, staged bundle and installed bundle; entitlements match the previous app.

The existing regression suite passed 33 tests, with one existing test skipped and
zero failures. It ran under `org.Petrichor.zak.skin-tests` to isolate library and
preferences. The two existing Swift warnings in PlaylistSyncTests remain.

A source audit compared all 27 modified Swift files with the starting commit:
manager command lines, event handlers and keyboard hooks are unchanged. Window
minimums, split constraints and the 110pt player height are unchanged. No Models,
Managers or Configuration files changed. Native visual and audible acceptance
remain a user check; source/build/tests do not establish those.

Installed: `/Users/zakcupido/Applications/Crate Mac.app`.
Previous bundle and receipt:
`/Users/zakcupido/Documents/Codex/checkpoints/2026-10-14-crate-mac-skin/`.
Build/test logs: `/private/tmp/crate-mac-skin-{build,tests}.log`.

Appearance fallbacks now use Light with artwork tint disabled. Existing explicit
user preferences are preserved, and the existing Appearance controls still work.
