# Mac Refinement, Preview and Exports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver consistent Crate naming, isolated single-track Preview, and usable text/Rekordbox exports through existing Mac controls.

**Architecture:** Keep UI layout and normal playback intact. Add entry-scoped playback purpose, immutable export snapshots and pure formatters, with engine/filesystem effects owned by existing native managers.

**Tech Stack:** Swift/SwiftUI, GRDB, XCTest; TypeScript, Expo SDK 57, SQLite, Jest; existing Dropbox transport and credentials.

**Spec:** [Connected Crate](../../specs/2026-10-14-connected-crate/README.md), [02-mac-refinement-preview-and-exports.md](../../specs/2026-10-14-connected-crate/02-mac-refinement-preview-and-exports.md).

## Global Constraints

- Read the [governing specification](../../specs/2026-10-14-connected-crate/README.md) first for absolute roots, baseline refresh, command helpers and release gates. `M:` means the Mac root; `P:` means the newest accepted phone root; `L:` means the old phone sync donor. Paths marked Create are proposed new files; other paths already exist unless explicitly described as integration destinations.
- Node 24; pinned dependencies; SQLite access stays in `src/library/`, native filesystem in `src/storage/`, one native player in `src/player/`. Read exact Expo SDK 57 docs before changing Expo integration APIs.
- Keep Mac minimum 1100×600, default 1200×800, 110pt player, current CrateStyle, original-colour artwork and Light/Dark/Auto behavior. No Mac Digging. Preserve the newest accepted iPhone UI and unrelated dirty work.
- Stable Dropbox file IDs plus verified content/root bindings; no filename matching, SQLite sharing, credentials in shared records or logs, or writes through guessed roots. Reuse exact persisted bytes for immutable retries.
- No product implementation, installation, merge or release is authorized by writing this plan. Execute only after the user requests implementation; live acceptance follows the master release gates.

## Review Focus

- Text-field focus or radio source accidentally accepting Preview: tasks 1–3.
- Stale EOF crediting a Preview or changing a newer ordinary session: task 3.
- Short/unknown decoded durations and failed seek: tasks 2–3.
- Table sorting, shuffle or edits changing export order halfway through: task 4.
- Unicode paths, missing audio and fabricated technical fields in XML: task 5.

## File and interface map

UI: M `Models/Enums/Sections.swift`, `Views/Components/{PlaylistMenuBuilder,TrackContextMenu}.swift`, `PetrichorApp.swift`, `Views/Settings/GeneralTabView.swift`, existing playlist sheets and `Resources/Localizable.xcstrings`. Playback: M `Managers/{PlaybackManager,PlaybackQueueMirror,ScrobbleManager}.swift`, `Managers/Playlist/{PMPlayback,PMTrackUpdate}.swift`, `Application/{AppCoordinator,PlaybackSessionStore}.swift`, `Models/Core/PlaybackState.swift`. Exports: M `Managers/Playlist/PMImportExport.swift`, `Views/Playlists/Sheets/ExportPlaylistsSheet.swift`. All new tests below are XCTest files under M `Tests/`; currently the repository has no dedicated playback/export test suite.

### Task 1: Naming and native baseline comparison

**Files:** Modify UI owners above and authored localization entries; Create M `docs/verification/connected-crate/02-naming.md`.

**Interfaces:** Keep `Playlist`, `Sections.playlists`, database columns, IDs, notification names and user-authored collection names. Only user-facing labels change.

- [ ] Inventory labels with `rg -n 'Playlist|playlist|Playlists|playlists' Views Models/Enums PetrichorApp.swift` from M. Mark internal identifiers, radio Collections, M3U format terms and authored names as retained.
- [ ] Capture the baseline screens in every appearance mode and inactive-window selection. Record keyboard/menu order before editing.
- [ ] Replace authored strings with **Crates**, **New crate**, **Smart crate**, **Add to crate**, **Edit crate**, **Delete crate**, **Export crates** as appropriate. Keep the same layout/components and accessible labels. No automated global replace over identifiers.
- [ ] Build Mac; compare the same content, selected rows and split widths at 1200×800 and 1100×600. Check VoiceOver labels, focus, multiselection, drag/drop, sorting, scroll and Space behavior. This copy-only task needs no mirror-image unit tests.
- [ ] Commit just naming/resources and the comparison receipt. Naming can release alongside milestone 1 after its own visual check.

### Task 2: Preview policy and entry purpose

**Files:** Create M `Models/Playback/PlaybackPurpose.swift`, `Managers/Playback/PreviewPolicy.swift`, `Tests/PreviewPolicyTests.swift`; Modify M `Managers/PlaybackQueueMirror.swift` and `Managers/PlaybackManager.swift` to attach purpose to each engine entry.

**Interfaces:** New `enum PlaybackPurpose { case ordinary, preview }`; `PreviewPolicy.startSeconds(duration:fraction:minSeconds:maxSeconds:) throws -> Double`. Store purpose by `AudioEntryId`, not by visible current title or one global boolean. Default ordinary purpose is explicit at all existing queue/entry creation sites.

- [ ] Add the actual arithmetic tests:

```swift
XCTAssertEqual(try PreviewPolicy.startSeconds(duration: 300, fraction: 0.2, minSeconds: 20, maxSeconds: 75), 60)
XCTAssertEqual(try PreviewPolicy.startSeconds(duration: 21, fraction: 0.2, minSeconds: 20, maxSeconds: 75), 0)
XCTAssertEqual(try PreviewPolicy.startSeconds(duration: .nan, fraction: 0.2, minSeconds: 20, maxSeconds: 75), 0)
XCTAssertThrowsError(try PreviewPolicy.startSeconds(duration: 300, fraction: 2, minSeconds: 20, maxSeconds: 75))
```

- [ ] Run `mac_test PreviewPolicyTests`; require missing-policy failures.
- [ ] Implement finite settings validation and decoded-duration clamping:

```swift
let start = min(max(duration * fraction, minSeconds), maxSeconds).rounded()
return duration.isFinite && duration > 0 && duration - start >= 5 ? start : 0
```

Reject fraction outside 0…1 and nonfinite/negative/reversed bounds before evaluating duration. Keep entry purposes until queued/stale delegate events no longer need them.
- [ ] Test boundary values 0, 5, 20, 25, 375 seconds; verify per-entry purpose survives rapid replacement until its EOF is classified. Run policy tests and existing playlist tests.
- [ ] Commit. Deliverable: pure, tested policy and an entry-owned classification seam, with no Preview UI yet.

### Task 3: Isolated Preview session, restoration and accounting

**Files:** Create M `Managers/Playback/PreviewSession.swift`, `Tests/PreviewSessionTests.swift`; Modify the playback/session/scrobble/UI owners in the map and `Views/Settings/GeneralTabView.swift`.

**Interfaces:** New `@MainActor PreviewSession` exposes `begin(track: Track)`, `end()`, `cancelForOrdinaryPlayback()` and read-only `isActive`. It owns one original `PlaybackSession` snapshot plus an operation generation. Existing `PlaybackManager`/engine remains the only player. Make session snapshot/restore helpers internal and purpose-aware, preserving existing ordinary behavior.

- [ ] Add a fake implementation of the existing engine backend port that records load/seek/play/finish, supports a suspended seek completion and uses real `AudioEntryId`. Test A ordinary → B Preview → C Preview → End restores A's queue/origin/modes/position paused; test explicit normal Play discards restoration. Assert event order equals `[loadB, readyB, seekB, playB]` using the test's recorded strings.
- [ ] Run `mac_test PreviewSessionTests`; demonstrate absence of isolation. Include stale B seek after ordinary D starts: assert no seek/play for D was issued by the stale Preview operation.
- [ ] Capture ordinary queue/cursor/origin/shuffle/unshuffled order/repeat/position/intent once; repeated Preview replaces only audition. Verify generation and entry after each await; EOF pauses audition, never advances saved queue. End restores paused; unavailable ordinary track shows recovery without auto-skipping.

```swift
let token = generation
let intendedEntry = previewEntryID
// At ready/seek completion, before acting:
guard token == generation, intendedEntry == previewEntryID else { return }
```

Gate `incrementPlayCount`, last-played, Last.fm start/finish/enable-during-playback and ordinary-session persistence using actual entry purpose. Retain ordinary session on relaunch; Preview never enters handoff. Favourite/Add to crate remain ordinary deliberate edits.
- [ ] Add menu Preview beside Play and Option–Return only for one playable local selection without text focus/radio; disable Previous/Next in Preview. Test failed seek, delayed/stale EOF, cancellation, double Preview and radio exclusions; compare minimum-window player metadata and check ordinary gapless/crossfade audibly.
- [ ] Commit and complete a separate Preview source/native/audio acceptance receipt. Do not mark Preview accepted from engine mocks alone.

### Task 4: Immutable export snapshots and tracklist formatter

**Files:** Create M `Managers/Exports/CrateExportSnapshot.swift`, `Managers/Exports/TracklistFormatter.swift`, `Tests/CrateExportTests.swift`; Modify M `Managers/Playlist/PMImportExport.swift`, existing crate menu/export sheet. Phone `src/export/tracklist.ts` is a read-only behavior reference.

**Interfaces:** New `ExportTrack` value holds shared/native identity, optional verified local URL, title/artist/album/genre/label/key, optional bpm/duration/year/track/disc and technical fields. New `CrateExportSnapshot` holds crate name and ordered `[ExportTrack]`. `TracklistFormatter.render(_ tracks: [ExportTrack], numbered: Bool, includeLabel: Bool) -> String`. `captureExportSnapshot(playlistID: UUID) async throws -> CrateExportSnapshot` reads saved manual order or evaluates a smart collection once.

- [ ] Add formatter assertions using an `ExportTrack` initializer with optional fields defaulting nil:

```swift
let row = ExportTrack(title: "Tune", artist: "Artist", label: "Label")
XCTAssertEqual(TracklistFormatter.render([row], numbered: true, includeLabel: true), "01. Artist — Tune [Label]")
XCTAssertTrue(TracklistFormatter.render(Array(repeating: row, count: 100), numbered: true, includeLabel: false).hasPrefix("001. "))
```

- [ ] Run `mac_test CrateExportTests`; require missing formatter/snapshot failure.
- [ ] Implement numbering width from total count, Unknown Artist/Untitled fallbacks and label brackets only when enabled/nonempty. Capture saved canonical order independently of view sorting/shuffle; freeze value copies before async save panels/writes. Return an explicit empty result state for no members.
- [ ] Test 0/1/99/100+ outputs, Unicode, empty labels, sorted view versus saved order and a live edit after capture. Expose Copy tracklist/Save tracklist using native feedback and cancellation without writes. Text export needs metadata, not a fabricated audio path; retain unresolved entries only when their display metadata is available, otherwise show the explicit unavailable-item choice.
- [ ] Commit; record independent text-export acceptance with actual copied/saved content.

### Task 5: Rekordbox XML with verified local media

**Files:** Create M `Managers/Exports/RekordboxExporter.swift`, `Tests/RekordboxExporterTests.swift`; Modify M native export sheet and `PMImportExport.swift`; read P `src/export/rekordbox.ts` for supported XML structure only.

**Interfaces:** `RekordboxExporter.render(_ snapshot: CrateExportSnapshot) throws -> Data`; snapshots supply actual verified file URLs/technical metadata. XML track IDs are deterministic within the export and playlist references use those IDs. Keep existing M3U behavior.

- [ ] Build a temporary local audio fixture whose filename contains spaces, `&` and non-ASCII text. Parse generated XML with Foundation XMLParser; assert one collection node and one playlist reference, matching IDs, escaped title and file URL that resolves back to the exact file. Use fixture metadata 48000 Hz and the fixture's measured byte size; assert no hardcoded phone placeholder appears.
- [ ] Run `mac_test RekordboxExporterTests`; require absent exporter failure.
- [ ] Serialize verified title/artist/album/genre/label/key/BPM/duration/track/disc/year and available technical fields with correct XML escaping and URL encoding. Exclude unavailable paths before render only after the user sees exact items/count and chooses Export available tracks. Cancel writes nothing; multi-crate errors report per file. Never write tags, audio, cue points, beat grids or Rekordbox's database.
- [ ] Run formatter/XML tests, native build and actual save-panel cancellation. Import the file in the user's Rekordbox and play referenced tracks; record real observations separately from XML tests.
- [ ] Commit source and acceptance receipt. Rekordbox export remains its own completion gate even if naming/Preview/text export are already accepted.
