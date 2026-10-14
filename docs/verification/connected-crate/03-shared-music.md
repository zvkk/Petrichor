# Plan3 — explicit shared music publication

Native Task4 source candidate, 14 October 2026. Governing specification: [03 — Add to shared music](../../superpowers/specs/2026-10-14-connected-crate/03-add-to-shared-music.md). This receipt records source/native fixture evidence, not a release or real-account acceptance.

The existing File command and single/bulk track menus pass only their selected native track IDs. Shared-crate missing-member details dismiss before opening the same native confirmation. Unpaired/disconnected actions open existing connection settings. The sheet shows selected titles/count, total known bytes, paired folder, approved relative paths, collision/decoder uncertainty, original preservation and explicit outside-root copy consent. Fresh capture always requires Add; collision recovery requires a changed approved name. Inside-root paths retain their relative path, so collisions require the user to rename/move the original before selecting again.

The displayed full pairing, connection epoch and selected source paths are checked before any capture/copy. After Add, one journal transaction records all approved selections before provider work starts. Two globally bounded capture/upload/recovery jobs use one publication service. Pending/interrupted capture rows restore as manual recovery; cancelled work never starts automatically. Scope/pre-capture errors retain per-item journal failures. The existing notification popover shows durable independent successes/failures, session byte progress, Cancel, Retry and explicit read-only Check outcome. Library scan activity remains independent. Completion continues through the existing verified mapping transaction and sync notification.

## Native verification

Every native invocation used:

```sh
TEST_RUNNER_CRATE_SYNC_FIXTURE_PATH=/private/tmp/crate-plan3-fixture.json xcodebuild test -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/connected-crate-baseline -clonedSourcePackagesDirPath /private/tmp/petrichor-build/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile [focused -only-testing entries] PETRICHOR_APP_NAME='Crate Mac' PETRICHOR_BUNDLE_ID=org.Petrichor.zak.plan3-tests CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none -resultBundlePath [unique .xcresult]
```

- `crate-plan3-task4-final.log` / `.xcresult` under `/private/tmp`: publication presentation/source/service/mapping, **53 tests, zero failures** (10/12/20/11). This established the main source/UI implementation.
- `crate-plan3-task4-closeout.log` / `.xcresult`: **12 presentation tests, zero failures**, adding actual coordinator read-only outcome recovery with zero upload starts/finishes and unchanged-name collision rejection.
- Final handoff run and deliberate negative-control details are appended below.
- Host Info.plist independently reads `org.Petrichor.zak.plan3-tests`. Fixture SHA256: `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5`.
- Pinned SwiftLint: 11 inherited serious errors, zero new serious errors. New source has formatting warnings. Catalog symbol generation passes; all pre-existing catalog translation payloads remain identical. English count strings have plural variations. `git diff --check` passes.

Tests exercise the production coordinator/source/service with full temporary migrated SQLite databases, real temporary files and injected external scope/provider ports. Coverage includes confirmation cancel with zero captures/copies/journal writes, explicit outside-copy consent, exact selection, disconnected retained pairing, unpaired settings, changed connection/root, durable pending/cancelled items, bookmark failure, mixed durable results after reload, collision consent, and read-only uncertain finalization recovery. Existing source/service/mapping tests retain original/membership, streaming, no-overwrite and independent-item integrity evidence.

Fixture-backed NSHostingView confirmation and mixed-results PNGs are XCTest attachments. Initial transparent-background artifacts were unsuitable for inspection; subsequent captures use an explicit test-only native background. They verify those two fixture presentations, not the whole app, accessibility/keyboard behavior or owner acceptance. Product layout/player/window sizing code is unchanged except the added sheet/menu/tray affordances. No product fixture flags were added.

## Real acceptance remains OPEN

| Gate | Status and required evidence |
| --- | --- |
| A1 | OPEN — selected real audio reaches iPhone and actually plays; verify original hash/memberships. |
| A2 | OPEN — real large-file memory/restart/retry, one verified destination. |
| A3 | OPEN — real identical-byte reuse and different-byte collision, no overwrite. |
| A4 | OPEN — real outside-root consent/copy and unsafe path/symlink rejection. |
| A5 | OPEN — real changing/unavailable source, hash/decoder/quota/auth failures with exact item recovery. |
| A6 | OPEN — real blocked crate unblocks only after verified mapping, no invented membership edits. |
| A7 | OPEN — real cancel/disconnect/partial success, truthful results, preserved originals. |

No account calls/uploads, user audio/tag edits, installation, phone app-data changes, push or merge were performed. Real acceptance requires the separately authorized milestone1/live-write/device gate. No audible/device acceptance is claimed.

## Final handoff evidence

- `/private/tmp/crate-plan3-task4-handoff.log` / `.xcresult`: **24 tests, zero failures** (12 presentation + 12 source) after globally gating retry/outcome work and pinning selected source paths as well as pairing/epoch.
- `/private/tmp/crate-plan3-task4-negative-clean.log` / `.xcresult`: deliberate removal of the production outside-copy consent guard produces **1 test, 1 intended assertion failure**. Source was restored automatically in `finally`. This is regression sensitivity evidence, not chronological TDD. An earlier negative run also hit the intended assertion but then crashed because the test indexed the dismissed selection; the test now returns after that failed precondition.
- `/private/tmp/crate-plan3-task4-restored.log` / `.xcresult`: restored production source, **12 presentation tests, zero failures**. Built host identity independently rechecked isolated. Pinned lint handoff log retains 11 inherited serious errors and zero new; symbol generation succeeds and all 854 previous translation payloads are unchanged (40 Task4 keys added).
- Final fixture render exports: `/private/tmp/crate-plan3-task4-handoff-renders/F0BF06AA-DC8F-4C03-BE63-FB96F38563C5.png` (confirmation), `/private/tmp/crate-plan3-task4-handoff-renders/27582C9F-F488-41A7-8FFD-23FE067F1A52.png` (mixed results). Both were inspected directly. They remain fixture render evidence only.

Limits: journal/snapshots remain retained with no garbage collection. Interrupted captures require fresh explicit confirmation; restored upload/session rows require manual Retry. A missing native track or changed pairing before intent creation rejects the entire submitted selection without filesystem/provider effects and reports that preparation failed; no guessed source/root is substituted. Connection validity during copy is bounded by the existing connection epoch and pinned pairing checks before capture/copy and provider effects. Full application screen comparison, native interaction/accessibility and live/audio/device acceptance remain open.

## Final fix wave from 5a32651

Settings publication handoff now uses ContentView's actual PublicationPresentationOwner. Inner details dismissal invokes its onDismiss callback, which closes the owning Settings presentation; the root Settings onDismiss then requests the single confirmation. There is no delay used for sequencing and no competing Settings confirmation host. The production owner regression covers awaiting actual dismissal, selected-ID retention, Cancel/retry and zero journal/copy effects before Add. Main crate details retain the same inner-dismissal callback and use the root coordinator directly once dismissed. PublicationSheet and submit share coordinator.canSubmit, with source/filesystem safety rechecks retained. Publication-only trays use the localized Shared music results tooltip; activity and ordinary message counts retain precedence.

A final restored run exposed an existing publication-completion lock inversion: main actor journal read waited on GRDB, whose commit notification waited synchronously for the coordinator's main NotificationCenter queue. The primary verified `/private/tmp/crate-plan3-final-mac-hang.sample.txt` and authorized the narrow observer fix in this same wave. The production observer registration now uses queue:nil and retains its existing Task @MainActor scheduling. A private NotificationCenter regression uses the same production registration, an off-main GRDB commit and verified journal proof; it asserts the post returns while main is held, and the synchronous main read / delivered callback observe the committed proof. It uses fixture database/files and fake provider, no credential or account calls.

Evidence: initial presentation/source 26/26 pass; inverse premature confirmation 1/1 intended failure; affected observer/presentation/mapping/playlist suites 48/48 pass (15+11+22), including uncertain recovery; inverse .main observer queue 1/1 intended failure; final restored presentation 15/15 pass. Logs and xcresults use `/private/tmp/crate-plan3-final-mac`, `-negative`, `-observer`, `-observer-negative`, `-closeout` basenames. The pre-observer `-restored` run was terminated only after sampling the isolated stalled host; it is failed-run evidence, not a passing check. Every xcodebuild retained PETRICHOR_APP_NAME='Crate Mac', PETRICHOR_BUNDLE_ID=org.Petrichor.zak.plan3-tests, fixture override and pinned package/ad-hoc settings. Built-host Info.plist independently confirms Crate Mac / org.Petrichor.zak.plan3-tests. Symbols generate successfully; all 894 previous catalog payloads are unchanged and exactly one localized tooltip key was added. Pinned lint retains 11 inherited errors, zero new errors; whitespace passes.

These are source/fixture/native XCTest checks only. Live native Settings interactions, keyboard/focus/accessibility, real account/device/download and audible A1–A7 acceptance remain OPEN. No installation, actual account writes, credentials, upload, push or merge occurred. Shared DerivedData is released after final checks for primary integration.

## Primary integration verification — 14 October 2026

Source tested at `5d2f3611dfaea4d2683bf1690e7873c3da940428`, stacked on Plan2 `ef964ce`. Final whole-branch review and the single scoped fix review are complete: seven original findings plus the confirmed committed-notification deadlock are addressed, with no remaining scoped findings. Primary independently checked the source/integration tree equality and read the test results.

Full native command used the above template without any focused selection, with `PETRICHOR_BUNDLE_ID=org.Petrichor.zak.plan3-verification` and result `/private/tmp/crate-plan3-primary-full.xcresult` (log of the same basename). Exit 0, TEST SUCCEEDED: **127 total, 126 passed, 1 inherited skip, zero failures**. The skipped `FolderRefreshTests/testCopiedLibraryRefresh` requires an explicitly supplied library backup; no user backup was opened. The isolated host is `Crate Mac` / `org.Petrichor.zak.plan3-verification`, embedded XCTest remains `org.Petrichor.tests`. `codesign --verify --deep --strict` passes; sandbox/user-selected-file/network entitlements are present in the tested Debug host. This ad-hoc test signature is not a distribution signature.

Primary pinned SwiftLint reports **11 inherited serious errors, 463 warnings, zero new serious errors**. The inherited `syncNow` complexity decreases from 40 to 39; the comparison checks that same declaration rather than falsely treating the improved numeric message as new. Formatting warnings remain. Symbol generation passes in `/private/tmp/crate-plan3-primary-symbols`; all **854 Plan2 translation payloads** remain unchanged, 41 keys added (895 final). Canonical fixture SHA256 remains `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5`. Fixed-range `git diff --check` passes.

Phone companion at `251fae0bfca6b41b7d3e100180fd8fcbcd0a3b05`: full npm test passes **182 suites / 2,760 tests**, with one inherited opt-in search benchmark skipped; typecheck passes, lint zero errors/32 inherited warnings. No dependency installation. Latest accepted phone UI and native player/layout remain inherited.

The source PRs are [Mac #3](https://github.com/zvkk/Petrichor/pull/3) and [phone #96](https://github.com/zvkk/crate-app/pull/96). Source is ready for code review; all A1–A7, Plan1 live acceptance, hands-on Settings/keyboard/accessibility, physical phone/decoder/playback and audible acceptance remain **OPEN**. The installed app is unchanged. No real account upload, installation, main/QA data change, merge to main or release occurred. Snapshot/journal garbage collection is not implemented. Earlier sections remain chronological worker verification checkpoints, not current PR/push status.

## Review fixes — 14 October 2026

Mac publication-owned references now receive fresh remote and local proof verification before intent materialization and before outbox upload. Blocked immutable bodies retain their IDs, bytes and parent chains for recovery. The regression covers changed remote bytes before creation, changed bytes after queuing, and successful retry after proof restoration.

The current Plan2 review-fix commit `8dcedce` is merged into this branch. Combined native build/XCTest at `ad81b30` passes: **133 passed, one inherited skip, zero failures**. Log: `/private/tmp/crate-plan3-review/mac-merged-tests.log`. Pinned SwiftLint: same 11 inherited errors, 451 warnings, no new errors. Diff whitespace passes.

Phone companion fix `cb372af` classifies metadata path lookup failures and moved-outside audio as item failures while preserving root/auth failures. Full phone checks pass: typecheck, lint (zero errors / 32 inherited warnings), **2,765 tests passed / one inherited skip**. Logs: `/private/tmp/crate-plan3-review/phone-fix-*.log`.

No installation, real Dropbox upload or live playback was performed. Existing live A1–A7 acceptance remains open.
