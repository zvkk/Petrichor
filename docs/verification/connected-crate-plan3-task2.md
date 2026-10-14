# Plan3 Task2 — bounded resumable no-overwrite publication

Worktree `/Users/zakcupido/Desktop/Atlas/Worktrees/crate-plan3-upload`, branch `task/crate-plan3-upload`, base `94aa0a4`. Task2 source plus narrow Task1 FD correction only. No UI, mapping feature, live account calls, Keychain test access, audio edits, install, push or merge.

## Production interfaces for Task3 / Task4

- `PublicationService(source:transport:)` is an actor with an async `TransportFactory = (Publication) async throws -> any PublicationTransport`. `await run(id:)` records per-item sanitized outcomes. `try await cancel(id:)` increments the journal generation and persists cancellation. One service owns the application queue; max two active items and per-ID singleflight apply to both upload and outcome checks. No automatic startup retry is installed; callers must never automatically retry cancelled rows.
- `try await reconcileOutcome(id:)` is an explicit read-only remote outcome check for cancelled/uncertain rows. It never starts/resumes/appends/finishes uploads. Confirmed exact remote proof plus reverified source/copy/snapshot completes through the same completion transaction; definitive absence retains cancelled and clears uncertainty. Metadata/auth/root/network failure preserves uncertainty.
- `PublicationTransport` exposes `checkValidity()`, `metadataAtDestination()`, `start()`, `append(session:offset:bytes:)`, `finish(session:offset:)`. Append returns confirmed end offset. The concrete `DropboxPublicationTransport.verified(record:manager:authentication:)` reuses the native credential owner, verifies account+namespace+folder+descriptor, retains the exact existing App Folder probe, and checks pairing/connection validity before each effect, after each response, and before durable progress/completion. Optional credential-provider test seam never accesses Keychain in tests.
- `PublicationJournal.claim(_:)` transactionally increments generation and returns the claimed row. `cancel(_:)` increments generation; preserves finish uncertainty. Existing immutable save validation plus generation equality rejects stale workers. Completed rows cannot regress.
- **Task3 extension point:** `PublicationJournal.complete(_:proof:allowingCancellation:)` owns one GRDB write transaction. Extend this exact transaction to persist original-to-paired mapping and unblock crate intents. It currently validates generation (or exactly one cancellation increment when allowed), immutable snapshot/destination, verified remote proof, and saves completed. The static transaction-aware `save(_:in:)` remains available. Do not open nested writes.
- `PublicationError.finishUncertain` is durably stored with `.verifying` **before dispatching finish**. Ambiguous network/auth/process-death outcomes retain it. Actual Swift task cancellation leaves `.cancelled + .finishUncertain`; explicit Cancel during committed finish can still persist confirmed completion. UI can expose Check outcome using `reconcileOutcome`. Ordinary pre-finish cancellation remains `.cancelled + .cancelled`. A typed provider finish rejection (quota/auth/root/sessionExpired/needsNewName/contentMismatch) plus successful exact lookup proving absence clears uncertainty and preserves that recovery category through `journal.rejectFinish`. Unknown/lost/cancelled outcomes or failed lookup remain uncertain. A normal explicit `run` of verifying+finishUncertain inspects destination first and may safely resume; cancelled rows can only use explicit read-only outcome reconciliation.
- Native credential replacement/disconnect invalidates `PublicationConnectionEpoch.shared`. Legitimate access-token refresh does not replace the connection epoch, but refresh checks the epoch after its await before saving, preventing disconnect from resurrecting credentials. Factory captures epoch before credentials await. Re-pairing is independently checked against persisted captured pairing.

## Transfer / integrity behavior

Sequential empty start, max 8 MiB append, empty finish; max file size 2^41-2^22. Snapshot opened O_NOFOLLOW and read with bounded FileHandle reads; source/snapshot/copy hash and identity verification runs off actor/UI/DB locks. Every initial/retry/finalization path inspects the exact destination first. Equal hash+size+real ID+expected path/root may reuse proof; different existing bytes require a new name. Finish always uses add, autorename=false, strict_conflict=true, mute=true. Callback data is never completion proof: exact metadata and all local proof are independently verified before completing.

Each confirmed session/offset is durable. Lost append acknowledgement is accepted only when Dropbox correct_offset equals this immutable chunk's exact end; other offsets fail safely with the previous durable cursor retained. Expired sessions restart at most once per run and only after destination lookup. Lost finish response checks destination before any second upload. No token is persisted in journal rows. Provider errors are reduced to auth/root/quota/contentMismatch/needsNewName/retryable/sessionExpired; raw responses and credentials are never logged/displayed.

Task1 FD correction puts defer immediately after each successful open in verifySourceAndCopy, so a later failed open cannot leak an earlier descriptor. Existing source production tests cover the helper; no separate mirror-only FD test was added.

## Official API verification

Execution-time official sources opened 14 October 2026:
- https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-start (JS-only response)
- https://raw.githubusercontent.com/dropbox/dropbox-api-spec/main/files.stone (official schema, successful full text)
- Primary pinned reference `/Users/zakcupido/Documents/Codex/connected-crate-plan-3/dropbox-reference.md` and `dropbox-files.stone`.

Official schema confirms 150 MiB per request, seven-day sessions, 2^41-2^22 maximum file size, incorrect_offset acknowledgement recovery, and finish lookup/path failure distinctions. Our 8 MiB/two-item bounds are lower implementation limits. No real provider requests were made by tests.

## Validation evidence

Every xcodebuild command includes:

```sh
TEST_RUNNER_CRATE_SYNC_FIXTURE_PATH=/private/tmp/crate-plan3-fixture.json xcodebuild test -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/connected-crate-baseline -clonedSourcePackagesDirPath /private/tmp/petrichor-build/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile [focused -only-testing entries] PETRICHOR_APP_NAME='Crate Mac' PETRICHOR_BUNDLE_ID=org.Petrichor.zak.plan3-tests CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none [-resultBundlePath unique-path]
```

Fixture SHA256 independently verified `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5`. Built host Info.plist independently reads `org.Petrichor.zak.plan3-tests`.

- `/private/tmp/crate-plan3-task2-first.log`: initial compiler failure from test UInt64 literal arithmetic; fixed.
- `/private/tmp/crate-plan3-task2-second.log`: 21/21 (service+source).
- `/private/tmp/crate-plan3-task2-third.log`: 37/37; fourth 40/40; final 41/41; reviewed 43/43 as further regression cases were added.
- `/private/tmp/crate-plan3-task2-missing-service.log`: deliberate negative control, automatic source restoration, fails `cannot find PublicationService in scope`. This was after implementation, so chronological TDD red-first was not achieved.
- `/private/tmp/crate-plan3-task2-outcome.log` and `.xcresult`: **44 tests, zero failures** (16 service, 5 concrete native session transport, 12 source, 11 existing Dropbox metadata transport). The outcome command also contained an inert misspelled PETRICHICHOR_APP_NAME setting alongside the correct mandatory PETRICHOR_APP_NAME; the correct isolated host identity was retained.
- `/private/tmp/crate-plan3-task2-closeout.log` and `.xcresult`: final service-only rerun after O_NOFOLLOW read and outcome-check queue bound. 16 tests, zero failures.
- `/private/tmp/crate-plan3-task2-rejection.log` and `.xcresult`: final service regression for provider-confirmed rejection plus exact absent lookup; 17 tests, zero failures.
- Pinned `/private/tmp/crate-plan2-swiftlint/bin/swiftlint lint --quiet`: **11 inherited serious errors, zero new serious errors**, `/private/tmp/crate-plan3-task2-lint-closeout.log`. New files have formatting warnings. `git diff --check` passes.

Coverage includes finish-accepted/lost-response and metadata-loss retry; no second start; different-content collision; confirmed offset resume and expiry restart; max chunk and concurrency bounds/per-ID singleflight; cancel before upload/during append/after committed finish; actual Task.cancel then explicit read-only committed/absent outcome recovery; quota/auth/root/network and setup classifications; pending credential and response invalidation; stale generation rejection; snapshot tamper; source mutation before finish; remote hash mismatch; independent completed/failed items. URLProtocol fixtures inspect production native endpoint/scope/no-overwrite/ASCII header behavior. Tests use real temporary GRDB/files.

## Scope limits

Task3 must add atomic mapping/intents, Task4 must own one service instance and expose queue/retry/cancel/Check outcome UI with localized copy. Cancellation never deletes remote files. No snapshot garbage collection is installed; immutable operation-owned snapshots are retained. Source/native regression verification is established; full integration/UI/live-account/device/playback acceptance remains with primary and later gates.

## Primary-review closeout

Initial scoped commit: `87ca748e1fada0c201d41bbe1f449e4dceba2334` (follow-up classification commit follows).

After exact metadata/hash matches, a sourceChanged/unavailableSource/unavailableScope/integrity failure is a known remote result with blocked local mapping. Both upload finalization and explicit outcome reconciliation persist the local-proof category; no mapping/completed state is written, and the remote file is untouched. An already cancelled row remains cancelled with the truthful local-proof category. Added regressions mutate the original after committed finish and before read-only outcome recovery.

`/private/tmp/crate-plan3-task2-local-proof.log` and `.xcresult`: 18 service tests, zero failures. Final shared-helper and read-only regression evidence `/private/tmp/crate-plan3-task2-handoff.log` and `.xcresult`; 19 service tests, zero failures. Host Info.plist rechecked `org.Petrichor.zak.plan3-tests`; final lint remains 11 inherited serious errors and zero new serious errors. No scope expansion or live acceptance claimed.
