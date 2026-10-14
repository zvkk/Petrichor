# Add to Shared Music Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish explicitly selected Mac audio into the verified shared root and make it playable on phone without changing the original.

**Architecture:** A separate publication journal owns source snapshots, bounded streaming upload and verified mapping. Reuse pinned auth/root verification, but never widen v1 JSON upload methods into arbitrary-media upload.

**Tech Stack:** Swift/SwiftUI, GRDB, XCTest; TypeScript, Expo SDK 57, SQLite, Jest; existing Dropbox transport and credentials.

**Spec:** [Connected Crate](../../specs/2026-10-14-connected-crate/README.md), [03-add-to-shared-music.md](../../specs/2026-10-14-connected-crate/03-add-to-shared-music.md).

## Global Constraints

- Read the [governing specification](../../specs/2026-10-14-connected-crate/README.md) first for absolute roots, baseline refresh, command helpers and release gates. `M:` means the Mac root; `P:` means the newest accepted phone root; `L:` means the old phone sync donor. Paths marked Create are proposed new files; other paths already exist unless explicitly described as integration destinations.
- Node 24; pinned dependencies; SQLite access stays in `src/library/`, native filesystem in `src/storage/`, one native player in `src/player/`. Read exact Expo SDK 57 docs before changing Expo integration APIs.
- Keep Mac minimum 1100×600, default 1200×800, 110pt player, current CrateStyle, original-colour artwork and Light/Dark/Auto behavior. No Mac Digging. Preserve the newest accepted iPhone UI and unrelated dirty work.
- Stable Dropbox file IDs plus verified content/root bindings; no filename matching, SQLite sharing, credentials in shared records or logs, or writes through guessed roots. Reuse exact persisted bytes for immutable retries.
- No product implementation, installation, merge or release is authorized by writing this plan. Execute only after the user requests implementation; live acceptance follows the master release gates.

## Review Focus

- Outside-root files, symlinks, reserved metadata destinations and changing sources: task 1.
- Crash after server finalization but before local acknowledgement: task 2.
- Same filename with different audio or a different encoding: tasks 1–2.
- Canonical reconciliation losing original-source membership or invalidating proof: task 3.
- Cancel/disconnect after partial success and phone decoder failure: task 4.

## File and interface map

Create M `Managers/SharedMusic/` for publication service/journal/transport and `Models/SharedMusic/Publication.swift`; extend `Managers/Database/DatabaseMigration.swift` append-only. Existing owners: `Managers/PlaylistSync/{DropboxPlaylistAuthentication,DropboxPlaylistTransport,DropboxPlaylistMapping,PlaylistSyncStore}.swift`, native track/File menus, `Views/Components/Widgets/NotificationTray.swift` and folder security scope in `Managers/Library/LMFolders.swift`. P ingestion remains `src/storage/` and existing download/media-claims code.

### Task 1: Stable source capture and durable publication intent

**Files:** Create M `Models/SharedMusic/Publication.swift`, `Managers/SharedMusic/{PublicationJournal,PublicationSource}.swift`, `Tests/PublicationSourceTests.swift`; Modify M `Managers/Database/DatabaseMigration.swift`.

**Interfaces:** `PublicationID` is a UUID. `PublicationSource.capture(trackID: Int64, destinationRelativePath: String) async throws -> PublicationID` runs only after explicit confirmation. Persist original track ID, original path/bookmark reference, snapshot path/stat/hash, relative destination, operation generation and state. Native paths remain local. Journal states: queued, capturing, uploading, verifying, completed, cancelled, failed.

- [x] Add temp-file tests: `a/../.crate-sync/x`, absolute destination and escaping symlink are rejected; source bytes modified during capture prevent queued upload. Assert original SHA-256 and membership rows unchanged for a valid outside-root copy.
- [ ] Run `mac_test PublicationSourceTests`; require missing service failure. Use a temp security-scope adapter; never alter the user's actual files in unit tests.
- [x] Append a journal schema with stable ID and immutable snapshot identity; copy selected outside-root sources into the user-confirmed paired root without overwrite. Keep security-scoped access until capture ends, compare source identity/size/mtime/hash before and after reading. Persist operation before starting network work.

```sql
CREATE TABLE shared_music_publication (
 id TEXT PRIMARY KEY, track_id INTEGER NOT NULL, generation INTEGER NOT NULL,
 source_snapshot BLOB NOT NULL, destination TEXT NOT NULL, state TEXT NOT NULL,
 upload_session BLOB, verified_mapping BLOB, error TEXT
);
```

- [x] Test invalid/unavailable bookmark, source path move, crash/reopen while capturing, confirmed copy collision and transaction rollback. Confirm only selected files are read; no recursive watched-folder publisher is introduced.
- [x] Commit. Deliverable: A4/A5 capture safety and restartable intent without uploads.

### Task 2: Chunked, resumable no-overwrite publication

**Files:** Create M `Managers/SharedMusic/{PublicationTransport,PublicationService}.swift`, `Tests/PublicationServiceTests.swift`; extend auth/transport verification seams without changing v1 body rules.

**Interfaces:** `PublicationService.run(id: PublicationID) async` and `cancel(id:)`; injected transport offers start/append/finish and exact-destination metadata/hash lookup. Use two concurrent items maximum and 8 MiB chunks as implementation bounds, validated against provider limits before execution. Journal provider session/offset after each confirmed chunk; never store tokens.

- [x] Fake transport accepts finish then throws a lost-response error. On retry, assert destination metadata/hash is checked first, no second upload starts, one verified completed ID is persisted. Test differing-content existing destination: no overwrite and state requires user-approved new name.
- [ ] Run `mac_test PublicationServiceTests`; require missing resumable finalization behavior.
- [x] Verify current Dropbox upload-session API from official documentation at execution, retaining pinned app/root scope. Stream immutable snapshot bytes; commit with no-overwrite/no-autorename. Equal-byte existing destination may reuse verified ID; different bytes require explicit rename/cancel. Persist final real file ID and Dropbox content hash only after verification.

```swift
// A completion callback is not publication proof.
let remote = try await transport.metadataAtDestination(destination)
guard remote.contentHash == snapshotDropboxHash else { throw PublicationError.contentMismatch }
try journal.complete(id: id, fileID: remote.fileID, contentHash: remote.contentHash)
```

Define `PublicationError` in `Publication.swift` with sourceChanged, invalidDestination, contentMismatch, needsNewName, auth, root, quota and retryable cases; transport maps provider failures without leaking response secrets.
- [x] Test chunk-offset retry, expired session restart, bounded memory/concurrency, cancellation before/after finish, quota/auth/root failure and disconnect. Independent completed items must remain completed when one fails. Verify snapshot size/hash again before finalization.
- [x] Commit. Deliverable: A2/A3/A5/A7 transport/journal coverage.

### Task 3: Verified publication mapping and original identity preservation

**Files:** Modify M `DropboxPlaylistMapping.swift`, `PlaylistSyncStore.swift`, publication journal/service; Create M `Tests/PublicationMappingTests.swift`; inspect native canonical/scanner owners before edits.

**Interfaces:** Existing `saveSyncMapping(fileID:trackID:hash:expectedPath:)` remains v1 mapping ingress. Extend local publication mapping to keep original-source identity and paired-copy identity/proof, rather than overwriting the original track path. `PublicationService` commits proof before scheduling blocked crate materialization.

- [x] Seed one original track outside the root in two crates and a paired copy. After verified publication, assert both native memberships and original path remain; the wire ref is the verified remote ID. Mutate original bytes and assert the next materialization is blocked until reverified.
- [ ] Run `mac_test PublicationMappingTests`; require current mapping path assumptions to be exercised.
- [x] Resolve original-to-published-copy through durable proof with source and copy hashes/identities, then reuse existing stable wire member capture. Do not merge WAV/FLAC/M4A by names or titles. Source-change invalidation must survive restart and cannot remove known remote wire members.
- [x] Test alias promotion, source/copy relocation, scanner reimport, mismatched content, cancelled mapping transaction and existing remote reference unavailable locally. Run `mac_test PlaylistSyncTests` too.
- [x] Commit. Deliverable: A6 unblock behavior preserves the original and full crate membership.

### Task 4: Native explicit action, phone availability and real acceptance

**Files:** Modify M `Views/Components/TrackContextMenu.swift`, `PetrichorApp.swift`, `Views/Components/Widgets/NotificationTray.swift`; Create M `Views/SharedMusic/PublicationSheet.swift`, `Tests/PublicationPresentationTests.swift`, M `docs/verification/connected-crate/03-shared-music.md`. Modify P ingestion presentation only if its current states fail spec 03; do not add another scanner.

**Interfaces:** Native sheet submits selected track IDs and approved destinations to task 1 only after Add N tracks. Result items map to Added, Already shared, Needs a new name, Source changed, Failed; Cancel and retry reference publication IDs.

- [x] Test presentation from journal rows: one completed and one failed operation yields both results/counts; Cancel before confirmation invokes capture zero times. Disconnected action opens existing connection settings.
- [x] Run `mac_test PublicationPresentationTests`; implement the existing-style sheet and progress surface. Show total known bytes, destination, collision/format warnings, original preservation and outside-root copy consent. Crate sharing never implicitly invokes publication.
- [x] Test phone remote-only discovery, current wanted/offline retention, crate-before-audio arrival and unsupported decoder failure. Metadata completion and actual playability remain separate states.
- [ ] Run master checks; after milestone 1/live-write authorization use selected test audio for A1–A7. Verify originals/hashes/memberships, real download/playback, partial cancellation and exact per-item result evidence.
- [x] Commit source and receipt. No automated uploads or raw-tag writeback are introduced.

## Execution checkpoint

Tasks 1–4 are source-complete and reviewed. Primary full integration evidence is in [the receipt](../../../verification/connected-crate/03-shared-music.md). The unchecked missing-behavior/red-first commands were not consistently established chronologically; bounded negative controls and final regression coverage are documented instead. The combined master/live A1–A7 step remains open. No Plan4 work, installation, actual account upload or release.
