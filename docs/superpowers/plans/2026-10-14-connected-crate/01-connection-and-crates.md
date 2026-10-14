# Connected Collection and Regular Crates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate existing v1 sync into the accepted phone app and prove a real Mac → phone → Mac crate round trip.

**Architecture:** Reuse the existing Mac and donor phone protocol/store/transport. Reconcile schema histories and transplant only the sync feature, wiring every current mutation transaction and native presentation owner.

**Tech Stack:** Swift/SwiftUI, GRDB, XCTest; TypeScript, Expo SDK 57, SQLite, Jest; existing Dropbox transport and credentials.

**Spec:** [Connected Crate](../../specs/2026-10-14-connected-crate/README.md), [01-connection-and-crates.md](../../specs/2026-10-14-connected-crate/01-connection-and-crates.md).

## Global Constraints

- Read the [milestone specification](../../specs/2026-10-14-connected-crate/README.md) first for absolute roots, baseline refresh, command helpers and release gates. `M:` means the Mac root; `P:` means the newest accepted phone root; `L:` means the old phone sync donor. Paths marked Create are proposed new files; other paths already exist unless explicitly described as integration destinations.
- Node 24; pinned dependencies; SQLite access stays in `src/library/`, native filesystem in `src/storage/`, one native player in `src/player/`. Read exact Expo SDK 57 docs before changing Expo integration APIs.
- Keep Mac minimum 1100×600, default 1200×800, 110pt player, current CrateStyle, original-colour artwork and Light/Dark/Auto behavior. No Mac Digging. Preserve the newest accepted iPhone UI and unrelated dirty work.
- Stable Dropbox file IDs plus verified content/root bindings; no filename matching, SQLite sharing, credentials in shared records or logs, or writes through guessed roots. Reuse exact persisted bytes for immutable retries.
- No product implementation, installation, merge or release is authorized by writing this plan. Execute only after the user requests implementation; live acceptance follows the master release gates.

## Review Focus

- Conflicting migration 11 histories and unknown existing table shapes: task 2.
- Browse/rule Digging Undo ownership and scanner-only disappearance: task 4.
- Invisible unresolved refs or aliases changing beneath an editor: task 5.
- Dropbox cursor reset, wrong root and equal-ID/unequal-byte retries: task 3.
- Sharing a crate with one unmapped local-only member: tasks 4–6.

## File and interface map

Existing donor modules: `L:src/playlist-sync/{protocol,dropbox,coordinator,events,index,store,use-playlist-sync}.ts`, their `__tests__`, and `L:src/library/playlist-sync-{capture,store}.ts`. These become corresponding P destinations; no whole-app replacement. Mac owners are `M:Managers/PlaylistSync/`, `M:Models/PlaylistSync/`, `M:Managers/Database/DMPlaylists.swift` and the existing settings/menu surfaces. Phone DB edits stay under `P:src/library/`.

### Task 1: Freeze the integration baseline and compatibility fixture inputs

**Files:** Create M `docs/verification/connected-crate/01-baseline.md`; retain M/P `docs/fixtures/dropbox-playlist-protocol.json`. Read M `docs/dropbox-playlist-protocol.md`, P `AGENTS.md`, P/L `src/library/schema.ts`, M/P existing tests.

**Interfaces:** Consume exact v1 JSON bytes; produce the baseline receipt and identical protocol fixtures for existing `PlaylistRevision.decode(_:)` and `decodeRevision(body, expected?)`.

- [ ] Refresh three HEAD/status receipts and identify owner of every dirty P file before modifying it. Record current migration count by inspecting `MIGRATIONS`; do not assign the old donor migration index to the target.
- [ ] Inventory all current crate writers using this search and classify each as explicit user mutation or projection/source maintenance:

```sh
rg -n 'INSERT.*crate_tracks|DELETE.*crate_tracks|UPDATE.*crate_tracks|INSERT.*crates|DELETE.*crates|UPDATE.*crates' "$CRATE_PHONE_ROOT/src/library"
rg -n 'capturePlaylistIntent|savePlaylist|deletePlaylist|addTrack|removeTrack' "$CRATE_MAC_ROOT/Managers"
```

- [ ] Run P `phone_test src/library/__tests__/schema.test.ts` and M `mac_test PlaylistSyncTests`; record actual baseline results, not old counts from the 10 October plan.
- [ ] Compare fixture hashes and capture Mac baseline screens specified in the master gate. Preserve the accepted phone app visuals and current dirty changes.
- [ ] Commit only the new baseline/fixture documentation. Deliverable: execution roots, writer inventory and untouched current-state evidence.

### Task 2: Append and validate the phone sync schema

**Files:** Modify P `src/library/schema.ts`, `src/library/db.ts`; Create P `src/library/playlist-sync-schema.ts`, `src/library/__tests__/playlist-sync-migration.test.ts`; inspect donor schema and P `test-support/sqlite.ts`.

**Interfaces:** New `validatePlaylistSyncSchema(db: SQLiteDatabase): Promise<void>` validates required columns, primary/unique keys and indexes inside the append migration transaction. Existing `openLibrary(): Promise<SQLiteDatabase>` remains the public entry point. No schema-version constant is hardcoded before task 1.

- [x] Write fixtures for fresh DB, pre-v11 ordinary DB, old sync v11, current repaired v12, old sync after current repair, and incompatible same-name tables. Seed pairing/settings, exact revision bodies/outbox flags, pending paths, aliases, media ownership, crates, favourites and Digging sessions. Reuse real SQLite reset/preserve/failure injection helpers.
- [x] Add the core failure assertion, with existing test setup importing `openLibrary`, `closeLibrary` and `__resetDatabases`:

```ts
const db = await openLibrary();
await db.execAsync('DROP TABLE playlist_sync_downloads; CREATE TABLE playlist_sync_downloads (wrong TEXT)');
await expect(validatePlaylistSyncSchema(db)).rejects.toThrow('incompatible sync schema');
expect(await db.getAllAsync('PRAGMA table_info(playlist_sync_downloads)'))
  .toEqual([expect.objectContaining({ name: 'wrong' })]);
```

Run `phone_test src/library/__tests__/playlist-sync-migration.test.ts`; require failure before the validator exists.
- [x] Append the donor's three sync table definitions under the new actual migration version, using create-if-absent followed by shape validation. Invoke validation before the transaction's `PRAGMA user_version` update; reject incompatible shapes without rebuilding them. Existing `runMigrations` already wraps noninitial versions in a transaction: preserve that structure.

```ts
await db.withTransactionAsync(async () => {
  await db.execAsync(MIGRATIONS[version]);
  if (version === SYNC_MIGRATION_INDEX) await validatePlaylistSyncSchema(db);
  await db.execAsync(`PRAGMA user_version = ${version + 1}`);
});
```

Define `SYNC_MIGRATION_INDEX` in `playlist-sync-schema.ts` from the version pinned in task 1 and import it in db/tests. Never use the moving last-array index in historical tests.
- [x] Inject failure during DDL, validation and version checkpoint; reopen and compare rows/blobs and user_version to the pre-upgrade snapshot. Run new migration tests and existing schema tests. Expected: data preserved, no partial version advance, idempotent reopen.
- [x] Commit schema, validator and tests only. Deliverable: safe integration schema, C9 source evidence.

### Task 3: Port protocol, persistence and transport into the new phone tree

**Files:** Create the P destinations for donor modules/tests in the map above; merge P `src/storage/dropbox.ts` credential scope/access changes only where the donor requires them. Copy v1 fixture bytes, not old UI or schema history. Modify M `Tests/DropboxPlaylistTransportTests.swift` only for missing parity cases.

**Interfaces:** Preserve donor `PlaylistTransport.verify/upload/list/download/discoverTrack`, `syncPlaylists(transport?): Promise<void>`, `savePairing`, `recordDiscovery`, `pendingDownloads`, `materializeIntent`, `pendingUploads`, `ingestRevision` and `projectPlaylist`. Preserve P's current mutation/media-claims APIs rather than donor versions of them.

- [x] Port tests first. Extend the existing store setup's `shared()` fixture with exact-byte collision:

```ts
const crate = await shared();
await materializeIntent(crate.id);
const [{ body }] = await pendingUploads();
await expect(ingestRevision(body + ' ')).rejects.toThrow('collision');
expect((await pendingUploads())[0].body).toBe(body);
```

- [x] Run `phone_test src/playlist-sync/__tests__/store.test.ts` and `phone_test src/playlist-sync/__tests__/dropbox.test.ts`; require failures at absent adapters/imports before porting implementation.
- [x] Integrate modules without bypassing current `mutateLibrary`, canonical identity and media-claims boundaries. Preserve path/library identity validation, App Folder `/` evidence, strict add/no-autorename, 32-parent chains, download-before-cursor obligations and exact bytes. Copy only the credential behavior needed for the explicit pinned metadata transport; do not replace the current audio provider.
- [x] Extend fake transport tests: wrong descriptor causes zero uploads; specific App Folder probe permits only its documented fallback; generic 400 never does; cursor reset retains crates; child before parent stays pending; upload retry uses original bytes. Run protocol/store/dropbox/coordinator suites and `mac_test DropboxPlaylistTransportTests`.
- [x] Commit scoped integration. Deliverable: v1 feature works behind the existing fake transport in the latest phone schema, C1/C5/C6/C7 source coverage.

### Task 4: Capture every current explicit crate edit atomically

**Files:** Modify P `src/library/crates.ts`, `crate-edit.ts`, `triage-decisions.ts`, `browse-digging.ts`, `rule-digging-commands.ts`, `playlist-sync-capture.ts`, `track-lifecycle.ts`; extend P `src/playlist-sync/__tests__/store.test.ts`, `src/library/__tests__/browse-digging.test.ts` and `src/library/__tests__/rule-digging-commands.test.ts`. Modify M `Managers/Database/DMPlaylists.swift` only if task 1 finds an uncovered writer; extend M `Tests/PlaylistSyncTests.swift`.

**Interfaces:** Existing donor `captureCrateIn(db, crateId, deleted?, edit?): Promise<void>` stays transaction-local. `edit.removedIds` contains only proven explicit user removals; `renameOnly` retains the full prior wire list. Notifications fire after commit. Undo must return its actual successful ownership result before capture.

- [x] Parameterize current editor, rename/delete, ordinary add/remove/reorder, queue bulk creation, triage, Browse Add/Undo and rule Add/Undo tests. Seed a shared crate with one unresolved wire ref and assert after each command:

```ts
const state = await readState(crate.id);
expect(state!.intent!.members.some(m => m.ref?.fileId === 'id:missing')).toBe(true);
expect(state!.intent!.generation).toBeGreaterThan(beforeGeneration);
```

`crate` and `beforeGeneration` are captured by each existing command test's fixture before invoking its real writer. For a failed or no-longer-owned Undo, assert the intent/generation equals its pre-command snapshot and outgoing notification count is zero.
- [x] Run focused changed writer suites and the sync store suite; prove a newly covered writer currently lacks capture.
- [x] Insert capture inside each owning transaction after final membership is known and before commit. For delete, capture the tombstone before removing the native crate row. Preserve Browse/rule ownership tokens; skipped tracks never remove membership. Scanner removal/canonical promotion only changes mappings/projection. Network/mapping awaits remain outside DB locks.
- [x] Inject rollback into membership+capture and into ownership transfer; assert neither native state nor intent commits. Race mapping with a newer edit and verify materialization rejects the older generation. Confirm one blocked crate does not stall another.
- [x] Commit writer changes and tests. Deliverable: C3/C4/C5/C7/C8 transactional behavior through the current production entry points.

### Task 5: Protect current editors and native projections

**Files:** Modify P `src/library/crate-edit.ts`, `playlist-sync-store.ts`, `track-lifecycle.ts`; extend P `src/library/__tests__/crate-edit.test.ts` and sync store tests. Check M `playlistEditorSnapshot`/`savePlaylistEditor` in `Managers/PlaylistSync/PlaylistSyncStore.swift` and M `Tests/PlaylistSyncTests.swift`.

**Interfaces:** Extend current `CrateEditSnapshot` with the donor sync token rather than replacing its canonical membership conflict checks. `syncTokenIn(db, crateId)` includes invisible wire/mapping generation; existing `saveCrateEdit({ baseline, name, orderedTrackIds })` remains the command.

- [x] Add this assertion after the existing fixture receives an extra unresolved reference:

```ts
await expect(saveCrateEdit({ baseline, name: 'stale', orderedTrackIds: [] }))
  .rejects.toMatchObject({ code: 'conflict' });
expect(await readState(crate.id)).toEqual(stateAfterIncoming);
```

- [x] Run `phone_test src/library/__tests__/crate-edit.test.ts` and `mac_test PlaylistSyncTests`.
- [x] Check the sync token inside the save transaction; suppress echo during remote apply; materialize existing intent before projection or retain the incoming revision as pending when mapping blocks it. Reorder alias groups while keeping unresolved slots; explicit removal drops exactly the captured visible group.
- [x] Test Cancel writes zero rows; alias promotion stales a draft; source deletion never truncates wire membership; incoming state preserves local_uri/media ownership and native cache invalidation. Run both platforms' relevant suites.
- [x] Commit. Deliverable: editors cannot overwrite invisible incoming state, C7/C8.

### Task 6: Expose connection, sharing, conflict and recovery in current native shells

**Files:** Modify M `Views/Settings/DropboxPlaylistSyncSettingsView.swift`, `Views/Components/PlaylistMenuBuilder.swift`, `Views/Playlists/PlaylistDetailView.swift`, `Managers/PlaylistSync/DropboxPlaylistSyncCoordinator.swift`; port L `src/components/settings/playlist-sync-settings.tsx` into the corresponding P destination and merge lifecycle/settings integration into P `src/app/_layout.tsx`, `src/app/(tabs)/settings.tsx`, `src/app/(tabs)/library/crates/[id].tsx` and `src/components/crates/crate-actions.tsx`. Create P `src/components/crates/shared-crate-status.tsx` and `__tests__/shared-crate-status.test.tsx`.

**Interfaces:** Status UI consumes donor `SharedState`/`SyncStatus`; actions use share/sync/disconnect/resolve services, never direct SQL. Mac uses existing `connect`, `pair(remotePath:)`, `share`, `syncNow` and conflict methods. Keep native menus and existing settings layout.

- [x] Add async component tests using awaited render/unmount: for `intent !== null`, expect **Changes waiting to sync**; for a conflict, **Changes on both devices**; assert tapping Review changes dispatches once with the currently displayed head set. Fixture `SharedState` comes from the real shared-store setup, not a hand-built partial cast.
- [x] Run `phone_test src/components/crates/__tests__/shared-crate-status.test.tsx`; require absent UI/action failures.
- [x] Implement every state/action in spec 01's table, full conflict versions and delete-versus-edit; show unavailable counts independently of synced metadata. Add per-crate explicit Share with Mac/iPhone, exclude smart/radio/built-ins, retain state on disconnect. Wire foreground and postcommit edits through existing 400–500ms debounce.
- [ ] Hands-on keyboard/focus/native-sheet and rendered baseline comparison remain open under C10. Source stale-head/Cancel/delete-copy/Details behavior and focused tests pass; this checkbox does not infer native UX from tests.
- [x] Commit. Deliverable: feature is reachable from accepted native UI with no unrelated redesign, C2/C6/C10.

### Task 7: Complete milestone 1 acceptance

**Files:** Create M `docs/verification/connected-crate/01-connection.md`; product corrections remain with their owning task.

- [ ] Run the master full source/build gate. Record actual test results and preserved schema/fixture hashes.
- [ ] Perform authorized backup/install preparation from the master gate; record installed build identities and stable backup receipts.
- [ ] Use one real mapped three-track crate for C1–C3, then C4 Digging/queue edits, C5 offline+restart, C6 concurrent/delete conflicts, C7 missing/moved/alias audio. Record both directions and actual played recordings. Do not manipulate the user's other crates as fixtures.
- [ ] Confirm C8–C10 regression/source evidence, UI comparison and owner acceptance; retain all failed cases as open checkboxes.
- [ ] Commit the acceptance receipt when accurate. No push/merge/release is implied. Milestone 1 completes only with the spec's required live evidence.

## Execution checkpoint

Plan1 source implementation and final two-axis review passed; Mac39passed/1existing skip, phone2691passed/1existing skip. No later milestone implemented. Live C1–C7, native owner checks and fresh backed-up installation remain open; phone locked at preflight. See docs/verification/connected-crate/01-connection.md. Do not mark milestone complete from source/build evidence.
