# Connected Crate — specification

Date: 14 October 2026. Status: draft for user review; source-grounded and self-reviewed. This package specifies future work. It does not change either application or authorize an installation, merge, or release.

## Intended result

Crate Mac and Crate iPhone should behave as two native clients of the user's collection: the same shared music, crates and deliberate edits, with controls suited to each device. The current Mac app is the design and interaction baseline to refine. Its layout, player and established workflows are strengths to preserve.

The user explicitly excluded **Digging on Mac**. There is no Mac Digging tab, inbox, sorting session, decision history, swipe-card UI or Digging recommendation service in this package. Existing iPhone Digging remains functional; when it deliberately changes a shared crate, that membership change participates in ordinary crate sync.

## Authority and inspected baselines

| Surface | Baseline and authority |
| --- | --- |
| Mac | `feat/crate-mac-skin`, commit `e989f59246b0e0668b73ac3530e974be5ca60b3c`; installed Crate Mac at `/Users/zakcupido/Applications/Crate Mac.app`, bundle ID `org.Petrichor.zak.debug`. The user accepted its current appearance after opening it. |
| Newer iPhone source | `crate-petrichor-integration`, HEAD `3107e2c2bc4af3568dbe5cc6ea9da758b402f6e4`, currently on `fix/native-glass-transition`. Native-glass/player changes are actively dirty. Preserve them; this is an inspected source baseline, not proof of the precise installed phone binary. |
| Existing iPhone sync | `crate-dropbox-playlists`, `feat/dropbox-playlist-sync`, HEAD `4c6567f`. The newer iPhone tree does not contain `src/playlist-sync`; the old feature must be integrated forward. |
| Existing protocol | [Dropbox playlist protocol](../../../dropbox-playlist-protocol.md). Its v1 identities, immutable revisions, missing-member preservation and conflicts remain the manual-crate contract. |

Source roots used throughout this package:

- **Mac:** `/Users/zakcupido/Desktop/Atlas/Dev/Petrichor/.worktrees/crate-dropbox-sync`.
- **iPhone:** `/Users/zakcupido/Desktop/Atlas/Worktrees/crate-petrichor-integration`.
- **iPhone sync:** `/Users/zakcupido/Desktop/Atlas/Worktrees/crate-dropbox-playlists`.

Before implementation, record fresh HEAD/status for all three, confirm the newest accepted iPhone baseline, and coordinate with its active work. Never reset its dirty changes or substitute the old sync branch's UI. The older Ideaverse design note supports own-file music and curation; its uppercase/pastel styling does not override the current Mac skin.

## Deliverable specifications and order

| Milestone | Specification | Dependency and completion gate |
| --- | --- | --- |
| 1. Connected collection and regular crates | [01 — Connection and crates](01-connection-and-crates.md) | First: one real crate makes the Mac → iPhone → Mac round trip, including matched playback and restart. |
| 2. Mac product refinement | [02 — Mac refinement, Preview and exports](02-mac-refinement-preview-and-exports.md) | Naming can accompany milestone 1. Preview, text export and Rekordbox export each ship independently after their own acceptance. |
| 3. Mac-only audio | [03 — Add to shared music](03-add-to-shared-music.md) | Requires milestone 1. Explicit publication, separate from crate metadata. |
| 4. Shared track state | [04 — Favourites and metadata](04-shared-track-state.md) | Requires milestone 1 and extension capability support on both clients. |
| 5. Shared smart crates | [05 — Portable smart crates](05-portable-smart-crates.md) | Requires shared track-state/catalogue support from milestone 4. |
| 6. Continue listening | [06 — Playback handoff](06-continue-listening.md) | Requires milestone 1 and both clients' handoff capability; does not require smart-rule sharing. |

For Mac-only audio the planning assumption is a manual **Add to shared music** action. The optional question about automatic uploading has not been answered at authoring time; no watched-folder uploader is assumed. A different user preference requires revising specification 03 before implementation.

Milestones 3–6 are fully described product contracts, not hidden additions to the first connection release. Each needs a separate implementation plan and acceptance. Do not make the first connection depend on delivering all of them together.

## Mac design and interaction contract

Retain the toolbar tabs and search, left sidebar structure, persisted split positions, native tables and column chooser, album grids, context menus, right queue/lyrics/details panel, settings sheet, mini player and immersive mode. Keep current window minimums of 1100×600, default size 1200×800, sidebar constraints and 110pt bottom player. Do not reproduce the browser mockup's relocated navigation or permanent alternative player panel.

Reuse `Views/Components/CrateStyle.swift`: paper `#FFFFFF`, sidebar `#FAFAFA`, ink `#282828`, secondary `#757575`, hairline `#E8E8E8`, controls `#F3F3F3`, selection `#E7E7E7`, 2pt artwork corners, 14pt medium item titles and 12pt metadata. Existing detail-title, sidebar, table and transport type roles stay at their current sizes. Respect the existing Light/Dark/Auto options and corresponding skin colours. Album artwork stays in original colour.

Use existing `TabbedButtons`, `ListHeader`, native menus/sheets, `ControlButtonStyle`, keyboard handling and focus conventions. New controls use the same spacing and feedback as their immediate neighbours. Preserve selection, sorting, multiselection, drag/drop, scroll restoration, double-click playback and Space-to-toggle except while editing text. Network waits cannot delay local feedback or hold UI/database locks. Do not add a dashboard of sync statistics or a second player shortcut.

Status belongs in the existing Integrations settings and the affected crate/track. Surface a brief error inline with a recovery action. Backend IDs, revision graphs, callback URIs and permissions jargon belong in optional diagnostic details, not the normal user flow.

## Shared data boundaries

Both applications retain their own database, media cache and audio engine. Share explicit domain records through Dropbox, never SQLite files. The paired account, namespace, music-folder identity and library ID remain pinned. Stable Dropbox file IDs identify recordings; native integer IDs, runtime UUIDs, filenames and local paths do not.

Keep manual crates on the existing `.crate-sync/v1` protocol. New catalogue/track-state, smart-rule and handoff documents use separate `.crate-sync/v2` feature namespaces bound to the **same verified v1 library descriptor**. They must not rewrite v1 bodies or add fields that old clients would silently ignore. A versioned feature manifest advertises each persistent device ID's supported features; unsupported features show **Update Crate on your other device** and retain pending work. Manual-crate sync continues independently.

New feature records require strict codecs on both platforms, identity/path agreement, bounded payloads, exact persisted bytes for retries, durable discovery before cursor advancement and transactionally captured local intent. Different new-document bodies under the same immutable ID are integrity errors. A file missing from Dropbox is not a user deletion. Credentials stay in Keychain/SecureStore and never enter shared files, fixtures, logs or specs.

Audio download state, device volume/output, EQ, ReplayGain, local paths, local-only files, preview settings, Digging state and listening-history aggregates remain device-local. Custom artwork and raw audio-tag writeback are not part of metadata sharing. Handoff is explicit playback transfer, not continuous remote control.

## Verification and release contract

| Evidence | Required before calling that milestone complete |
| --- | --- |
| Source/data | Focused tests, cross-language fixtures where relevant, migration/reopen/rollback tests and preserved unrelated data. |
| Mac | Native build, deep/strict signature check, same installed identity/entitlements, and direct comparison with baseline screens at normal and minimum window sizes. |
| iPhone | Node 24, pinned dependencies, typecheck, lint and `npm test`; native build plus complete verified Documents/Library backup before any in-place main-app installation. Never uninstall the main or QA apps. |
| Real connection | Real account/root pairing, both directions, offline/retry/conflict cases, restart and actual matched audio playback. |
| Owner experience | Native keyboard/focus/accessibility/reduced-motion checks and hands-on audible acceptance. A build, unit test or paired-account label does not establish these. |

Capture Mac Home, Library table/grid, album detail, crate detail/editor, queue and Settings before implementation. Compare the same content/state afterward. Each acceptance record identifies source/build IDs, devices, fixtures, observed outcome and remaining gaps; retain a recoverable previous application bundle and appropriate data backups.

## Self-review result

Checked the current Mac skin, both iPhone schema histories, current manual-crate writers, canonical aliases, Preview/play recording, both smart-rule models and export owners directly. The old phone sync branch's migration 11 conflicts with newer history; specification 01 requires append-only schema reconciliation. Current iPhone smart rules are `SmartRuleV2`; the legacy `SmartCrateRule` interface is not the full current model. Specification 05 accounts for that distinction.

All discussed capabilities have a named specification and acceptance gate. Mac Digging is excluded throughout. No implementation step, live sync, audio upload, app-data migration or application install was performed while writing this package.
