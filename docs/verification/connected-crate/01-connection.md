# Plan 1 verification — 14 October 2026

Scope: connected collection and ordinary manual crates only. No other milestone implementation. Code review and live acceptance remain separate.

## Source receipts

Accepted Mac source9523a45 (skin e989f59), current phone93bb94a, sync donor4c6567f. The newest phone source includes footer correction not yet represented by the prior installed6b41f18 build. Main/QA applications and user databases have not been modified during implementation.

Implementation branches: `feat/connected-crate-plan-1` in both existing repositories. PRs: Mac https://github.com/zvkk/Petrichor/pull/1 and phone https://github.com/zvkk/crate-app/pull/84. Central spec issue76, task issues77–83. Source merge mappings and task reports are retained privately in `/Users/zakcupido/Documents/Codex/connected-crate-plan-1/`.

## Observed checks

- Unchanged baseline: phone schema28/28; MacPlaylistSync16/16.
- Appended phone migration13: schema/migration42passed; historical1–12 SQL byte hash unchanged; fresh, ordinary, old sync11, repaired12 and old sync+repair fixtures preserve rows, queued bytes and ownership; invalid shape and interrupted migration roll back.
- Protocol parity: production Swift/TypeScript agree on27revision,10descriptor,12graph cases and accepted revisions round-trip both ways. Canonical fixture SHA256 `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5` matches across clients.
- Integrated Mac full XCTest:40executed,39passed,1pre-existing skip,0failures. `/private/tmp/connected-crate-mac-full-tests.log`.
- Mac production-identity build and deep/strict signature verification pass; bundle ID and entitlements match installed Crate Mac. Private candidate receipt saved under `/Users/zakcupido/Documents/Codex/checkpoints/2026-10-14-connected-crate-plan-1/`.
- Phone writer integration full suite at086290c:173suites passed,2659tests passed,1pre-existing skip. All11 temporary donor integration skips enabled. Final integrated reviewed phone checks at7c6c67b: typecheck passed; lint0errors32existingwarnings;177suites and2691tests passed, one existing suite/test skipped. `/private/tmp/connected-crate-phone-reviewed-source.log`.
- Library import graph static pass from new store/capture/writer/editor modules:30reachable modules,0cycles. This is not native-runtime warning evidence.

Mac tests used an exact-byte `/private/tmp` copy of the canonical protocolfixture via test-only environment override after a separate worker's sandboxed test host blocked on Desktop access. No privacy permission was changed. Initial new phone worktrees lacked ignored generatedExpo type references; restoring those cleared five environmental TypeScript errors without a product change.

## Acceptance matrix

| ID | Source/build evidence | Required live result |
|---|---|---|
| C1 | Pinned-root/descriptor rejection and wrong-root zero-write tests pass | OPEN: real account/root/library pairing |
| C2 | Explicit sharing/projection production services and native controls | OPEN: real three-track Mac→phone crate with actual playback |
| C3 | Ordinary/editor/bulk/triage transactions and rollback tests pass | OPEN: edits round-trip in both directions |
| C4 | Browse/rule Add+token-owned Undo tests pass; Skip/no-op/later owner emits no removal | OPEN: real queue/Digging shared-membership round-trip |
| C5 | Immutable retry, durable discovery/reopen/outbox tests pass | OPEN: real offline edit/restart/reconnect |
| C6 | Stale head, current distinct Keepboth, deletion/edit tests pass | OPEN: real concurrent and deletion conflicts |
| C7 | Unresolved refs, alias groups, source disappearance, unmapped whole-crate blocking tested | OPEN: real moved/missing/disconnected audio |
| C8 | Sync token plus current editor/canonical checks, generation recheck, transactional rollback tested | OPEN: native runtime/editor interaction |
| C9 | Append-only migration and preservation tests pass | OPEN: backed-up main-app migration and reconnect |
| C10 | Current native structures retained; no player/dependency overhaul; Mac native build passed | OPEN: paired visual, keyboard/focus/accessibility and owner comparison |

No live C1–C7 or audible acceptance is claimed. No main-device install, data migration, app deletion, real sync write or audio upload has been performed. Live acceptance requires matching reviewed candidates and fresh verified backups. The code PRs can be reviewed independently; milestone1 remains incomplete until the open live checks are observed. Later milestones remain untouched.

## Final review and corrections

Independent Standards review returned one P2; Spec review returned three P2. One implementer fixed all four in213d65f, merged into phone7c6c67b: device-local remote availability with verified local-file existence; disconnected/global auth/root status; legacy/tokenless shared Undo preservation; settled-generation connection/settings UI readers. Regression tests include failed-transaction races and inverse guard removal, later-owned membership, deleted remote files/local copies/reappearance, and exact UI positions. No protocol or migration change was needed. Scoped independent re-review: all four ADDRESSED;62/62focused tests passed, no new breakage in fix range. Mac remains475e8a7, with no final review finding.

Phone read-only preflight reported passcodeRequired=true. No app process was stopped. The current installed phone and its data remain unchanged. Prior verified backup migration rehearsal preserved every original row, including200tracks and2crates, and passed integrity; it is explicitly not a fresh live backup. A private guarded install plan identifies both exact installed targets and requires explicit confirmation before a schema13 main-app update.

Repeatable source commands: phone `nvm use 24`, `npm run typecheck`, `npm run lint`, `npm test`. Mac full XCTest uses existing project/schemePetrichor with destination `platform=macOS,arch=arm64`, pinned Package.resolved and isolated test identity `org.Petrichor.zak.plan1-baseline-tests`; production candidate uses existing `org.Petrichor.zak.debug`. Cross-language check: `python3 docs/verification/verify-dropbox-protocol.py --ios-root <phone-checkout>`. Do not use test identity for the main Mac app, and do not install an old/pre-fix phone build.

Final reviewed iPhone Release build from7c6c67b succeeded. Candidate signature, same signing/keychain identity, connected-device profile/expiry, embedded provider configuration, normal entry point and current UI markers verified. Demo data disabled; migration count13. Private source manifest and build receipt match exact reviewed production code. Candidate is not installed.
