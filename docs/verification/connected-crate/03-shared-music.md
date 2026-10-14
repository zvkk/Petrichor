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
