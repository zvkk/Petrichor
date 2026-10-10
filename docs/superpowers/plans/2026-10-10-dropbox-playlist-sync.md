# Dropbox Playlist Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Crate Mac's selected playlists appear as Crate iPhone crates, and editable collections synchronize both ways over Dropbox with durable offline edits and explicit conflicts.

**Architecture:** Each application owns its native library and a durable sync store. Native edits atomically capture full snapshot intents; mapping turns these into immutable shared revisions before any incoming projection is applied. Dropbox stores paired-library metadata and immutable revisions; a revision DAG detects conflicts without clock ordering.

**Tech Stack:** Swift/SwiftUI, GRDB and native URLSession/AuthenticationServices/Keychain on Mac; React Native/Expo SDK 57, TypeScript, SQLite, existing Dropbox OAuth/SecureStore on iPhone. Node 24 for iPhone checks. No new service or dependency.

**Spec:** `docs/crate-mac-playlist-sync-scope.md`; locked wire contract `docs/dropbox-playlist-protocol.md`.

## Global Constraints

- Mac implementation workspace: `/Users/zakcupido/Desktop/Atlas/Dev/Petrichor/.worktrees/crate-dropbox-sync`, baseline `27ffcc5`.
- iPhone implementation workspace: `/Users/zakcupido/Desktop/Atlas/Worktrees/crate-dropbox-playlists`, baseline `aa61de5`.
- Preserve Petrichor's layout/navigation/player; use existing settings/dialogs/menus for required controls. Display name Crate Mac; bundle ID remains `org.Petrichor.zak.debug`.
- Only manually ordered, explicitly shared collections sync. Both directions, creation, rename, membership, order and explicit deletion are in scope. Audio deletion/upload, smart-rule sync and history are excluded.
- Missing local audio never removes a known remote reference; unmapped originating audio blocks only that playlist's publication with recoverable status.
- Capture full immutable snapshot intent + pinned parent baseline + generation in the same transaction as local edits; no plain dirty flag. Incoming projections never emit local edits.
- Separate account/root-verified Dropbox metadata transport from current audio-provider root inference. No account-root fallback on an error. Use independent device credentials; never print/store secrets in docs or logs.
- User explicitly authorized execution with GPT-6.1 Sol implementers and Astra supervisor/reviewer. Proceed through routine plan/review/checks without another approval request. No shared-branch push/merge or live cloud metadata writes during source verification.

## Review Focus

- Unresolved/alias entries and provider-driven deletion: preserve complete wire order and do not emit user removals from rescans; test in each platform store.
- Local edit before receive/upload: persist intent with baseline, keep incoming pending while mapping blocked, generation-check delayed mapping; test crash/reopen and concurrent receipt.
- Child-before-parent and same-ID/different-bytes: do not partially apply, skip data, acknowledge conflicting payloads or advance past undurable reads; transport/store tests.
- Stale native editors and invisible remote changes: compare sync generation in native-save transaction, not only visible rows; editor integration tests.
- Account/root change, write grant missing, expired token, cancellation: preserve outgoing work and previous binding; explicit setup/reconnect status, bounded retriable requests.

## Task 1: iPhone native sync and Dropbox integration

**Files:** Create `src/playlist-sync/{protocol,store,dropbox,coordinator,index}.ts`, matching tests and a small native-style settings component; modify library schema/db and mutation paths (`crates.ts`, `crate-edit.ts`, `triage-decisions.ts` and any other membership writers discovered), Dropbox OAuth scope, settings/foreground entry points. Follow existing native import boundaries: raw SQLite stays within `src/library/` (put persistence implementation there and expose via playlist-sync if necessary).

**Interfaces:** Consume `docs/dropbox-playlist-protocol.md` verbatim (read Mac absolute path). Produce strict revision decoder/head resolver; library transaction hooks; pairing/sync/share/conflict service; UI controls that make those services reachable. No unshare/detach action in v1. Local function names may follow repo conventions; wire names may not change. Parent owns fixture JSON, not your product files.

- [ ] Write failing tests using real test-support SQLite for atomic intent capture, rollback, unresolved members, revision ancestry, duplicates/collisions, generation checks and delete/edit conflict. Pattern:

```ts
await shareCrate(crateId);
await renameCrate(crateId, 'After');
await reopenLibrary();
expect((await readPendingIntent(crateId)).name).toBe('After');
// A transport failure must leave this same intent/outbox available to retry.
```

Use actual exported implementation names in tests; this example specifies behavior, not a required public API.

- [ ] Implement strict protocol decoder, DAG/pending/conflict selection and raw-body collision validation. Run tests under Node 24; prove malformed versions/parents/duplicate file refs are rejected.
- [ ] Add migrations and transaction-local capture hooks across every user mutation, explicit suppression for apply/projection, source-change preservation and stale-editor guard. Capture immutable full ordered state (including unresolved references/native unmapped members), parent baseline and generation. Map and materialize exact wire bytes only after generation validation. Add native playback/downloading projection only for known Dropbox identities.
- [ ] Implement pinned Dropbox pairing, immutable upload, paginated/restartable discovery, independent per-playlist blocked states, retry/backoff/cancellation and account/root binding. Add `files.content.write` to OAuth flow. Verify current scopes/callback behavior from versioned Expo documentation before changing integrations.
- [ ] Add existing-style settings controls for connection/pairing/Sync Now/status/shared manual crates and conflict version choice/keep both. Trigger active foreground sync and debounced local edits. UI must expose missing tracks and blocking mapping/auth errors without leaking credentials.
- [ ] Run focused tests, then `npm run typecheck`, `npm run lint`, `npm test` exactly. Baseline is 125 passing suites, 1950 passing tests/1 skipped. Report pre-existing warnings separately; no install/push. Self-review diff, commit own code, write task report with paths/commands/evidence and remaining setup limitations.

## Task 2: Crate Mac native sync, auth, and integration

**Files:** Create small Swift files under `Managers/PlaylistSync/` and `Models/PlaylistSync/` for protocol, revision store, transport, auth/coordinator; extend `Managers/Database/` migrations and playlist mutation methods; tests `Tests/PlaylistSyncTests.swift` and focused transport fixtures. Integrate `Views/Settings/IntegrationsTabView.swift`, existing playlist menu builder, app foreground lifecycle and editor guards. Rename Dev display product in `Scripts/build-local.sh`/Xcode build/test-host paths, keep stable configuration unchanged.

**Interfaces:** Same wire contract and fixtures as Task 1. Persist native mappings, full wire order, snapshot intents, exact outgoing body, applied heads, pending remote revisions and cursor. All DB writes remain GRDB transactions; never call async network mapping inside one.

- [ ] Write failing protocol/store tests against temporary GRDB DBs, including rename/delete/reorder capture, rollback, unresolved members, alias projections, stale editor and crash/reopen.

```swift
let manager = try DatabaseManager(databaseURL: fixtureURL)
// Create a manual shared playlist in fixture storage, mutate its name,
// reopen the same DB, and assert full intent + parents survived together.
// Fail an edit transaction and assert neither native data nor intent changed.
```

- [ ] Implement the protocol/DAG/store and transaction-local snapshot capture at every native mutation seam. Preserve unresolved slots while applying visible reorder/removal. Incoming projection must not echo. Parent baseline includes unpublished local head; multiple remote heads stay conflict, missing parents stay pending.
- [ ] Implement URLSession Dropbox transport and ASWebAuthenticationSession PKCE; Keychain tokens, refresh, explicit account/root verification and immutable uploads. Pair the same `.crate-sync/v1` library descriptor as iPhone. Use public app key settings; no hardcoded secret. Keep Mac folder bookmarks and mapping local; never send absolute file paths.
- [ ] Wire native settings, selection of manual playlists to share, status/Sync Now/conflict resolution and foreground scheduling. Block publication of any playlist containing an unmapped local file instead of sending a partial list. Safely map local relative paths to pinned Dropbox file IDs after metadata/content verification; ambiguous matches remain actionable status.
- [ ] Change display name to Crate Mac, preserving Dev bundle ID/container/URL scheme. Include test-host executable path consistency. Do not replace installed app in this task.
- [ ] Run focused XCTest and build with cached dependencies. Existing baseline command:

```sh
xcodebuild test -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/crate-sync-mac-build \
  -clonedSourcePackagesDirPath /private/tmp/petrichor-build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none
```

Primary handles sandbox escalation if needed. Self-review, commit own product files, report concrete tests/remaining live dependencies. Do not modify primary-owned docs/fixtures or install app.

## Task 3: Cross-platform verification, Astra review and delivery

**Files:** Shared fixtures `docs/fixtures/dropbox-playlist-protocol.json` copied verbatim into the iPhone worktree; durable verification report `docs/dropbox-playlist-sync-verification.md`; implementation corrections belong to their platform owner.

**Interfaces:** Both platform tests read the same fixture bytes. Report tests, build, install, live cloud, real phone acceptance separately.

- [ ] Generate fixtures for initial/child/fork/tombstone/resolution, child-before-parent, duplicate-reference and bad-library/UUID payloads. Verify both decoders and DAG heads agree on every case; deterministic comparison must cover counts and IDs.
- [ ] Astra reviews each platform diff against spec/contract, then reviews whole integration. Primary verifies every finding directly and issues bounded Sol fix tasks. Resolve major data-loss/security/reachability findings before acceptance.
- [ ] Run final source checks once per final code state, Mac build/signature verification and iOS native build where environment permits. Test fake Dropbox transport both directions, offline/replay/conflict and missing tracks without changing real Dropbox.
- [ ] Inspect actual local music/Dropbox root mapping and native app registration readiness without printing credentials. Do not fabricate live test success or substitute snapshots for real sync. A required interactive Dropbox login/write-scope consent is a setup dependency, not a reason to leave independent code/tests unfinished.
- [ ] Before any in-place app update, create complete verified container/Documents+Library backups, check inventory/hash/SQLite integrity and preserve installed identities. If live setup cannot be completed without user sign-in, save exact build/branch/test/checkpoint instructions and report one concrete setup action. Do not uninstall, push, merge or claim two-way live sync until evidenced.

## Execution decisions

The user's “okay go ahead” explicitly authorizes building this agreed feature using the chosen agent roles. Internal plan generation/review is part of execution, not an additional approval gate. Mac and iPhone implementations may proceed independently only after the wire contract is locked. Astra reviews code read-only; primary retains diagnosis and integration decisions.
