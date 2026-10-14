# Shared Track State and Complete Catalogue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Synchronize explicit favourites/tag edits and establish acknowledged catalogue snapshots without losing local or pending work.

**Architecture:** Use independently versioned v2 feature envelopes and transaction-local field streams, while keeping v1 manual crates unchanged. Mac proposes catalogue generations; both persistent participants acknowledge exact dependencies/checkpoints, with base/favourites/tags scoped independently.

**Tech Stack:** Swift/SwiftUI, GRDB, XCTest; TypeScript, Expo SDK 57, SQLite, Jest; existing Dropbox transport and credentials.

**Spec:** [Connected Crate](../../specs/2026-10-14-connected-crate/README.md), [04-shared-track-state.md](../../specs/2026-10-14-connected-crate/04-shared-track-state.md).

## Global Constraints

- Read the [master plan](../2026-10-14-connected-crate.md) first for absolute roots, baseline refresh, command helpers and release gates. `M:` means the Mac root; `P:` means the newest accepted phone root; `L:` means the old phone sync donor. Paths marked Create are proposed new files; other paths already exist unless explicitly described as integration destinations.
- Node 24; pinned dependencies; SQLite access stays in `src/library/`, native filesystem in `src/storage/`, one native player in `src/player/`. Read exact Expo SDK 57 docs before changing Expo integration APIs.
- Keep Mac minimum 1100×600, default 1200×800, 110pt player, current CrateStyle, original-colour artwork and Light/Dark/Auto behavior. No Mac Digging. Preserve the newest accepted iPhone UI and unrelated dirty work.
- Stable Dropbox file IDs plus verified content/root bindings; no filename matching, SQLite sharing, credentials in shared records or logs, or writes through guessed roots. Reuse exact persisted bytes for immutable retries.
- No product implementation, installation, merge or release is authorized by writing this plan. Execute only after the user requests implementation; live acceptance follows the master release gates.

## Review Focus

- Receiving a manifest or acknowledgement before its dependency bodies: task 5.
- Bootstrapping absent/unknown favourites as false before both snapshots complete: task 6.
- Disabling one feature while a write is admitted or the other feature advances: task 7.
- Source rescan or remote projection erasing partial metadata/media fields: tasks 3 and 8.
- New edits between proposal, review and acknowledgement invalidating stale decisions: tasks 5 and 7.

## File and interface map

Foundation (also reusable by handoff): M `Models/ConnectedCrate/`, `Managers/ConnectedCrate/`; P `src/connected-crate/` for pure codecs/coordinators and `src/library/connected-crate-store.ts` for SQLite. New migrations append in existing platform migration owners. Feature files stay separate: field state, catalogue generations, bootstrap and local sharing preferences each own one module. UI uses current connection settings, track editor/details and conflict sheets.

### Task 1: Lock v2 capability and immutable-record contracts

**Files:** Create M `docs/connected-crate-v2-protocol.md`, `docs/fixtures/connected-crate/v2-foundation.json`, `Models/ConnectedCrate/FeatureProtocol.swift`, `Tests/FeatureProtocolTests.swift`; Create P `src/connected-crate/protocol.ts`, `src/connected-crate/__tests__/protocol.test.ts` and identical fixture copy.

**Interfaces:** Proposed common logical types below. Swift Codable equivalents must use identical keys/values. Types are new contracts, not claims about existing source:

```ts
export type Feature = 'catalogue' | 'favourites' | 'tag-edits' | 'smart-crates' | 'handoff';
export interface FeatureEnvelope {
  version: 1; libraryId: string; recordId: string; deviceId: string;
  feature: Feature; kind: string;
}
export interface CapabilityRecord extends FeatureEnvelope {
  feature: 'catalogue'; kind: 'capabilities'; deviceSequence: number;
  supports: Partial<Record<Feature, readonly number[]>>;
}
export interface StoredRecord { path: string; body: string; sha256: string }
export function decodeFeatureRecord(body: string, path: string, libraryId: string): FeatureEnvelope;
export function decodeCapabilities(body: string, path: string, libraryId: string): CapabilityRecord;
```

Capability records live at `.crate-sync/v2/devices/<deviceId>/<recordId>.json`; persist a monotonically increasing per-device sequence and reject same-sequence unequal content. Persist identity/sequence across normal restarts; lost identity requires explicit re-pairing, never silent adoption of a new participant. `FeatureEnvelope` is a discriminated decoding boundary: specific features reject unknown kinds/fields, never simply cast arbitrary JSON.

- [ ] Define full JSON fixture bodies for valid capabilities and malformed UTF-8/UUID/path/library/version, unsupported versions, repeated IDs/different bytes and oversize input. Use existing canonical UUID/control rules. Add this shape to both fixture consumers:

```ts
for (const c of fixtures.capabilities) {
  const decode = () => decodeCapabilities(c.body, c.path, c.libraryId);
  if (c.valid) expect(decode().deviceId).toBe(c.deviceId);
  else expect(decode).toThrow();
}
```

- [ ] Run `phone_test src/connected-crate/__tests__/protocol.test.ts` and `mac_test FeatureProtocolTests`; require absent-decoder failure.
- [ ] Implement strict field/type/version/path validation and bounded UTF-8 parsing. Protocol document defines a 2 MiB maximum default, smaller feature limits, identity hashing, canonical SHA-256 text encoding, exact stored-body hash, unknown-feature retention and Update Crate presentation. Never add fields to v1 revisions or modify its descriptor.
- [ ] Copy canonical fixture bytes to P, compare hashes and run both production codecs against every case. Test unsupported peers leave pending v2 work while existing v1 tests still pass.
- [ ] Commit contract/codecs/fixtures. Deliverable: capability/record foundation, independently usable by milestone 6.

### Task 2: Durable generic v2 storage and transport admission

**Files:** Create M `Managers/ConnectedCrate/{FeatureStore,FeatureTransport}.swift`, `Tests/FeatureStoreTests.swift`; Create P `src/library/connected-crate-store.ts`, `src/connected-crate/transport.ts`, `src/connected-crate/__tests__/store.test.ts`; Modify both existing migration owners and connection lifecycle only.

**Interfaces:** New TS `persistRecordIn(db, record: StoredRecord): Promise<void>`, `recordDiscoveryIn(db, feature: Feature, paths: readonly string[], cursor: string): Promise<void>`, `pendingFeatureUploads(feature): Promise<StoredRecord[]>`; Swift equivalents use GRDB transaction arguments. The narrow `FeatureTransport` verifies the existing pairing and performs immutable put/get/list for v2 records, separate from v1 body encoding and audio upload.

- [ ] Add real SQLite/GRDB fixtures for body collision, outbox bytes, per-feature cursor+obligation atomicity, crash/reopen and stale participant capability. Core assertion after a simulated response loss:

```ts
expect((await pendingFeatureUploads('handoff'))[0].body).toBe(originalBody);
await expect(persistRecordIn(db, { ...record, body: originalBody + ' ' }))
  .rejects.toThrow('integrity');
```

`record` is a decoded fixture from task 1; `db` is current `openLibrary()` in the real test DB. The failed insert must preserve the original row and outbox.
- [ ] Run `phone_test src/connected-crate/__tests__/store.test.ts` and `mac_test FeatureStoreTests`.
- [ ] Append tables for immutable records `(library, feature, record_id, path, body, hash)`, outbox admission, discovery obligations/cursors and persistent device capability sequence. Keys include library/feature; paths and body identities agree. Store discovery obligations before cursor advance in one transaction; upload acknowledgement removes only its exact record. Use auth/root verification from v1 with bounded retries, no fallback or secret logging.
- [ ] Test disabled/unsupported feature queues do not stall v1 or other features; injected transaction failures preserve previous cursor and work. Confirm no asynchronous network call holds a DB/UI lock. Run existing v1 regression suites on both clients.
- [ ] Commit. Deliverable: transport/persistence foundation can ship internally without enabling catalogue or tag sharing.

### Task 3: Field revision schema, validation and transactional local capture

**Files:** Create M `Models/ConnectedCrate/TrackFieldRevision.swift`, `Managers/ConnectedCrate/TrackStateStore.swift`, `Tests/TrackStateTests.swift`; Create P `src/connected-crate/track-fields.ts`, `src/library/shared-track-state.ts`, `src/library/__tests__/shared-track-state.test.ts`; Modify P `favourites.ts`, `tracks.ts`, and M `DMTrackUpdate.swift`, `PMTrackUpdate.swift`; append feature tables in migration owners.

**Interfaces:** Define field union and typed operations in both codecs. `FieldName` is exactly title/artist/album/albumArtist/genre/label/musicalKey/bpm/year/trackNumber/discNumber/favourite. `FieldOperation` is inherit or typed override. New TS `captureFieldIn(db, fileId: string, field: FieldName, operation: FieldOperation): Promise<void>` and `applyFieldRevisionIn(db, record: TrackFieldRevision): Promise<void>`; existing public `setTrackFavourite` and `updateTrackMetadata` retain signatures.

- [ ] Write fixture cases for every field boundary, NFC, exact trimming/control rules, null versus zero, empty string versus inherit, omitted/unknown fields and 64 KiB limits. Add a real metadata mutation test comparing all provider/media/ownership columns before/after; only requested display fields, their edit stamp and sync intent may differ.
- [ ] Run `phone_test src/library/__tests__/shared-track-state.test.ts` and `mac_test TrackStateTests`.
- [ ] Persist separate imported bases, per-field overrides, local intent, parent heads and capture sequence; suppress capture on remote apply. Capture local field value+projection+intent within the existing write transaction. For phone partial metadata changes, preserve the current merged-row behavior and `metadata_edited_at`; never use a sparse `upsertTrack` call.

```ts
await db.withTransactionAsync(async () => {
  // Existing canonical metadata update remains inside this transaction.
  await captureFieldIn(db, verifiedFileId, 'favourite', { kind: 'override', value: false });
});
```

Define `TrackFieldRevision` as envelope plus fileId, field, revisionId, sorted parentRevisionIds and FieldOperation. Paths use SHA-256 of UTF-8 fileId and exact body identity checks. Independent fields merge; different same-field values retain explicit conflicts; equal values resolve with a new revision covering parents.
- [ ] Inject rollback, replay, concurrent same/different-field edits, >32-parent resolution, source rescan and alias promotion. Assert no whole-row replacement, no scanner-originated intent and no remote Last.fm love/unlove call.
- [ ] Commit. Deliverable: field semantics and local transaction seam, still behind capability/settings gates.

### Task 4: Explicit enrollment and verified Mac base records

**Files:** Create M `Managers/ConnectedCrate/CatalogueEnrollment.swift`, `Models/ConnectedCrate/CatalogueBase.swift`, `Tests/CatalogueEnrollmentTests.swift`; Create P `src/connected-crate/catalogue.ts`, `src/library/shared-catalogue.ts`, `src/connected-crate/__tests__/catalogue.test.ts`; Create M/P `docs/fixtures/connected-crate/catalogue.json`; Modify native connection settings.

**Interfaces:** `requestEnrollment(fileIds: readonly string[]): Promise<void>` creates an immutable user-confirmed request. Mac `verifyEnrollment(requestID:) async` resolves IDs/content and normalized raw tags, then writes base records. Base body stores full fileId, contentHash, typed tag values, durationSeconds/lossless and ancestry. No local path/credential enters it.

- [ ] Add fixture assertions: confirmed `{id:a,id:b}` plus concurrent `{id:b,id:c}` produces `{id:a,id:b,id:c}` once; unconfirmed or missing requests never add/remove IDs. Wrong content or divergent base remains pending/review and retains last agreed base.
- [ ] Run catalogue/enrollment suites; require missing production enrollment handling.
- [ ] Add Choose shared tracks… using human-readable titles/count. Sharing crates or uploading audio alone never enrolls. Mac verifies original shared-file bytes/hash and raw tags; unavailable verification exposes Waiting for Mac verification. Missing source tags remain typed unknown; no Unknown Artist display fallback is seeded. Keep monotonic confirmed enrollment and original identities.
- [ ] Test identical concurrent bases, unequal contents, files absent from one device, duplicate aliases and restart/retry. Ensure library scan/root disappearance never becomes catalogue removal. Verify audio publication and v1 work independently.
- [ ] Commit. Deliverable: S1 enrollment and base records ready for finite generation proposals.

### Task 5: Generation manifest, dependency validation and acknowledgements

**Files:** Create M `Models/ConnectedCrate/CatalogueGeneration.swift`, `Managers/ConnectedCrate/GenerationCoordinator.swift`, `Tests/CatalogueGenerationTests.swift`; Create P `src/connected-crate/generations.ts`, `src/library/shared-generations.ts`, `src/connected-crate/__tests__/generations.test.ts`; extend common protocol doc/fixtures.

**Interfaces:** `GenerationManifest` contains library/participant IDs, generation UUID, parent generation, coverage, base-generation reference where applicable, chunk refs `{recordId,sha256,count}`, exact enrollment/base/head entries and both covered-feature publication checkpoints. `validateGeneration(input: GenerationValidationInput): GenerationValidationResult` is pure; its input includes manifest bytes/hash, decoded dependency records, participant checkpoints and current local capture frontiers. Result is `{status:'complete'}` or `{status:'pending'|'conflict'|'integrity', reasons: readonly string[]}`. Store admission is a separate transaction that rechecks those frontier tokens before persisting an acknowledgement.

- [ ] Extend fixtures with manifest-before-chunks, acknowledgement-before-manifest, missing parent, omitted/duplicate ID, hash mismatch, old participant, unpublished local sequence and disabled covered feature. Call production `validateGeneration` on each fixture and assert exact status/reasons on both platforms. A complete fixture must lose completeness when any referenced dependency is removed.
- [ ] Run `phone_test src/connected-crate/__tests__/generations.test.ts` and `mac_test CatalogueGenerationTests`.
- [ ] Implement Mac serialized proposal chains per coverage (base, favourites, tags). Freeze exact membership/head lists including explicit empty heads, bounded 2 MiB manifest/chunks and complete dependency hashes. Dependencies upload before manifest, but receivers remain order-independent. Phone checkpoint carries exact revisions through its durable capture sequence; pending intent prevents declaring that frontier published.

```ts
// Inside acknowledgement transaction after re-reading capture frontiers:
if (currentSequence !== validatedSequence) return { status: 'retry' as const };
if (validation.status !== 'complete') return { status: 'pending' as const };
await persistRecordIn(db, acknowledgementBytes);
return { status: 'acknowledged' as const };
```

`acknowledgementBytes` is a `StoredRecord` naming the exact manifest hash, library, participant and covered checkpoint; both verified participant acks establish agreement. Generation bytes never change after persistence. New known work requires a successor proposal, not patching an acknowledged generation.
- [ ] Test frontier change at every transaction boundary, crash/reopen, missing/corrupt chunks, disconnected participant, stale proposal delivery and eventual agreement after all valid records arrive. Acknowledged old snapshots remain historical; known newer work changes freshness status. Base-only agreement does not require favourite bootstrap; disabled favourites cannot stall a tags-only generation. No list cursor is accepted as proof of completeness.
- [ ] Commit. Deliverable: S2/S3 completeness and dependency boundary for milestone 5.

### Task 6: Positive-union favourite bootstrap without reseeding

**Files:** Create M `Managers/ConnectedCrate/FavouriteBootstrap.swift`, `Tests/FavouriteBootstrapTests.swift`; Create P `src/library/favourite-bootstrap.ts`, `src/library/__tests__/favourite-bootstrap.test.ts`; extend fixtures and generation storage.

**Interfaces:** New `captureFavouriteBootstrapIn(db, baseGenerationId: string, fileIds: readonly string[]): Promise<void>` persists exact covered IDs and verified positive selections. Completion is per library/fileId; output field revisions use task 3 and subsequent favourite generation uses task 5.

- [ ] Fixtures: Mac positive A, phone positive B, both verified-negative C yield A/B true and C false; missing phone snapshot or unresolved local favourite mapping leaves C unknown. Add late explicit unfavourite B and assert bootstrap cannot restore true.
- [ ] Run both bootstrap suites; require no premature false values and verify inverse mutation fails (force missing snapshot complete).
- [ ] Capture each participant's full covered snapshot against one agreed base-only generation. Seed only after both arrive and mapping checks complete; atomically recheck newer explicit field streams before writing seeds. Persist completed IDs; newly enrolled IDs get a new bootstrap subset, never an entire-library reset.
- [ ] Test duplicate/reordered bootstrap records, new enrollment during capture, local edit between seed preparation/commit, crash/reopen and disable before initial completion. Re-enable resumes original selections, routing later local-only divergence through task 7.
- [ ] Commit. Deliverable: S1/S2 bootstrap and favourite/unfavourite preservation.

### Task 7: Per-device feature gates and explicit re-enable reconciliation

**Files:** Create M `Managers/ConnectedCrate/SharingPreferences.swift`, `Tests/SharingPreferencesTests.swift`; Create P `src/library/sharing-preferences.ts`, `src/library/__tests__/sharing-preferences.test.ts`; Modify both native connection settings and task 3/5 capture/projection/admission seams.

**Interfaces:** `setSharingEnabled(feature: 'favourites'|'tag-edits', enabled: false): Promise<void>` closes gates atomically. `prepareSharingReview(feature): Promise<SharingReview>` returns per-field baseline tokens, shared/local values, queued intents and immutable revision IDs. `commitSharingReview(review, choices): Promise<void>` rechecks tokens, writes selected resolution/projection and enables in one transaction. Define `SharingReview` and choice union `use-shared|share-local` in this module; UI never serializes them as remote commands.

- [ ] Test off→offline unfavourite→remote change→on: before review commit, outgoing admission/projection are zero and local edits survive. Cancel retains off state. Use shared versus Share local must produce different, explicitly selected results. Retained immutable bytes compare exactly before/after; completed bootstrap count never increments.
- [ ] Run sharing preference suites; prove admission cannot race past the persisted gate and stale review fails without losing drafts.
- [ ] Persist preferences per device/library/feature plus local divergence at the last shared baseline. Off allows durable discovery but no visible projection or new network admission; admitted writes may complete and are reconciled. Re-enable downloads heads without applying them, resolves shared conflicts explicitly, and shows pending/local/incoming differences. Supersede unmaterialized intent only after choice; retain materialized bytes and append resolution over them/current heads. Resume after atomic commit.
- [ ] Test in-flight write response after off, restart, off while editor/review open, pending bootstrap and later enrollment. Assert favourites-off/tag-only generations still agree and tags-off/favourite+duration generations still agree. Known disabled-stream changes cannot invalidate unrelated feature snapshots.
- [ ] Commit. Deliverable: S4/S5 gates and user-visible reconciliation with no automatic retroactive publication.

### Task 8: Native metadata editor, cache projection and milestone acceptance

**Files:** Create M `Views/ConnectedCrate/TrackTagEditorSheet.swift`, `Tests/TrackTagEditorTests.swift`; Modify M `Views/Main/TrackDetailView.swift`, track menu, query/cache projection owners; Modify P `src/components/library/tag-fixer-sheet.tsx` and `src/app/(tabs)/settings.tsx`; Create P `src/components/settings/__tests__/shared-track-settings.test.tsx`; Create M `docs/verification/connected-crate/04-track-state.md`.

**Interfaces:** Editor baseline is a map of field→head/generation token. Dirty fields compare inside save transaction; untouched fields refresh. Save creates only selected overrides/inherit operations. Read-only technical fields remain display-only. One postcommit invalidation refreshes rows/grouping/player/export/smart caches without replacing player source or resetting selection.

- [ ] Test incoming title while title draft is dirty → Tags changed on your other device and retained draft; incoming genre while title dirty refreshes only genre. Cancel causes zero mutations; Reset to file tags creates inherit, empty string remains a deliberate override.
- [ ] Run editor/settings tests (await React Native render/unmount) and field-state suites; implement native compact Mac editor and reuse phone editor. Use these tags on both devices… lists fields and requires explicit confirmation; historical imported rows never become edits automatically.
- [ ] Exercise alias/rescan/relocation, album regrouping, current player labels, exports and favourite conflict sheet. Verify unchanged local_uri/provider/ownership/file hashes and zero remote-driven Last.fm love events.
- [ ] Run master full gate and real two-device favourite/tag edits plus S1–S5. Include clock skew, interrupted discovery and off/on reconciliation in recorded native observations.
- [ ] Commit receipt only when observed. Milestone completes independently of portable smart crates; preserve all unsupported/pending records.
