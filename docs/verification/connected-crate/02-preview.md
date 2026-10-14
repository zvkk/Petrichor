# Preview source verification — 14 October 2026

Source: `task/crate-plan2-preview`, base `67595ea`; naming prerequisites applied separately. Policy/entry-purpose commit `806f630`; isolated session/UI/accounting commit `7900b7e`.

Preview has one original ordinary runtime snapshot, a separate engine occurrence and a generation. Repeated auditions retain that original membership/order/cursor/origin/modes/position/intent. End restores paused, including a deferred entry/generation-checked seek; explicit ordinary Play discards restoration. Explicit queue edits and mode changes synchronously restore ordinary context before applying the edit. Deliberate favourite metadata remains current without changing captured occurrences/order. The existing backend's seek API is synchronous `Bool`; tests suspend readiness and reenter seek with replacement rather than inventing an async engine port.

Engine-entry purpose gates history, Last.fm entry points, enable-during-playback and ordinary-session persistence. Preview never becomes the persisted session. Purpose and artwork-free callback tracks remain while owned by the current queue or awaiting a terminal callback for an actually adopted/started entry. Replaced unstarted rows retire immediately; classified unowned entries release their records. Unknown IDs never infer ordinary playback. The engine is unchanged in production; internal backend and optional manager-engine initialization permit deterministic tests.

## Verification performed

The final full target invocation was:

```sh
TEST_RUNNER_CRATE_SYNC_FIXTURE_PATH=/private/tmp/crate-plan2-integration-fixture.json \
xcodebuild test -project Petrichor.xcodeproj -scheme Petrichor \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/crate-plan2-preview \
  -clonedSourcePackagesDirPath /private/tmp/petrichor-build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none \
  PETRICHOR_BUNDLE_ID=org.Petrichor.zak.plan2-preview-tests \
  'PETRICHOR_APP_NAME=Crate Mac'
```

Result: **55 tests, 0 failures, 1 existing optional skip**. The skip is `FolderRefreshTests.testCopiedLibraryRefresh`, which requires an explicitly supplied library backup. Preview coverage: 2 policy tests and 13 real `PreviewSession`/`PlaybackManager` tests through the actual `PlaybackEngine` facade and fake existing backend. History assertions read actual temporary GRDB/SQLite rows: audition play count stays zero and last-played remains nil; an ordinary EOF increments the intended ordinary recording.

Covered: exact load→ready→seek→play order; A→B→C→End restores A paused at 37 seconds; normal D supersedes stale readiness/seek/EOF/error/user-action/start; failed seek never plays; pause during suspended readiness never resumes early; decoded short duration/invalid stored settings; missing-file/directory/radio exclusions; queue insertion/removal/reordering/modes; deliberate favourite update across restoration; paused restoration superseded before readiness.

Final result bundle: `/private/tmp/crate-plan2-preview/Logs/Test/Test-Petrichor-2026.10.14_18-34-03-+1100.xcresult`. Full log: `/private/tmp/preview-full-suite-fixture.log`. Protocol fixture SHA-256: `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5`.

`codesign --verify --deep --strict '/private/tmp/crate-plan2-preview/Build/Products/Debug/Crate Mac.app'` passed. Built test host ID verified as `org.Petrichor.zak.plan2-preview-tests`. `git diff --check` passed.

## Earlier failures and corrections

Initial missing-policy test execution was blocked by nested dependency sandboxing, so no missing-policy compiler failure is claimed. The isolated retry initially used the wrong global bundle-ID override and failed Xcode test product construction; subsequent commands use the host-specific build setting above. Missing PreviewSession compilation failure was observed before implementing that session. Tests exposed an unowned reference during manager teardown; teardown now disconnects/stops the engine directly. Temporary SQL fixture setup required real folder IDs and complete nonoptional metadata; corrected fixtures pass. A full suite without the existing fixture override blocked at Desktop access and was stopped; final full execution uses the byte-identical sandbox-readable fixture.

## Acceptance still pending

No installation, current-app control, live library access, audible acceptance or owner approval was performed. Native screen comparison at 1200×800 and 1100×600; inactive-window/Light/Dark/Auto selection; actual Option–Return focus/shortcut conflict testing; VoiceOver/reduced motion; long metadata; real decoder readiness/seek failure; ordinary audible gapless/crossfade; and live Last.fm/network/relaunch persistence observation remain pending. Build/tests establish source behavior, not those acceptance gates. No existing default layout, dock height, colour artwork or production engine defaults were replaced.

## Final review fixes (14 October 2026)

Queue replacement retires unstarted rows immediately. Only current ownership and actually adopted/started entries awaiting terminal classification retain purpose and artwork-free callback tracks. Start identity is retained before deferred UI processing, including a gapless successor replaced in the same main-loop turn. Terminal classification releases unowned records; current completed entries remain identifiable until replacement. Unknown IDs never gain ordinary purpose. No time-based eviction is used.

Restoration builds ID/URL indexes once, retaining current-track-first metadata precedence, saved occurrence order/cursor and deliberate favourite updates. Missing originals refresh backend Now Playing metadata; empty snapshots clear it. Both paths clear audition mirror/unmirrored/lookahead ownership. Fresh Music's actual single selection now supplies the focused Preview command; its normal Return handler accepts only unmodified Return with no editable responder. Source coverage does not establish native focus acceptance.

Final covering native run: **24 tests, zero failures, zero skips** (17 Preview session, 2 policy, 3 crate export, 2 Rekordbox). Includes 30 rebuilds of a 2,000-row queue with bounded ownership and no retained artwork, late ordinary EOF versus late Preview EOF, a started successor replaced before its UI callback, and backend metadata observations for missing/empty restores. Existing favourite/order restoration regression passes.

```sh
TEST_RUNNER_CRATE_SYNC_FIXTURE_PATH=/private/tmp/crate-plan2-integration-fixture.json \
xcodebuild test -project Petrichor.xcodeproj -scheme Petrichor \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/crate-plan2-preview \
  -clonedSourcePackagesDirPath /private/tmp/petrichor-build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:PetrichorTests/PreviewSessionTests \
  -only-testing:PetrichorTests/PreviewPolicyTests \
  -only-testing:PetrichorTests/CrateExportTests \
  -only-testing:PetrichorTests/RekordboxExporterTests \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none \
  PETRICHOR_BUNDLE_ID=org.Petrichor.zak.plan2-final-tests \
  'PETRICHOR_APP_NAME=Crate Mac'
```

Final log: `/private/tmp/crate-plan2-final-tests-verified.log`. Result: `/private/tmp/crate-plan2-preview/Logs/Test/Test-Petrichor-2026.10.14_18-45-52-+1100.xcresult`. Built host Info.plist independently reports `org.Petrichor.zak.plan2-final-tests`. Fixture SHA-256 remains `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5`. Earlier `final-tests.log`, `-2`, `-3` and `-final` logs are superseded attempts; only `-verified` covers the final source/catalog.

Pinned SwiftLint 0.63.3 final report: `/private/tmp/crate-plan2-final-lint.json`; 11 pre-existing baseline errors, zero new errors. Both introduced export line-length errors are fixed. Export error/format/fallback/AppKit/menu/toast strings are localized; stable format identities and dynamic filenames/titles remain intact. Catalog symbol generation passes, with all 827 prior payloads preserved and 27 keys added. Automation displays Crate labels while retaining internal identifiers and existing playlist Siri phrases alongside crate phrases.

All previously recorded native appearance, focus/Option–Return, accessibility, audible gapless/crossfade, real clipboard/save-panel and Rekordbox acceptance gaps remain open. These are source/backend tests, without GUI, installation, phone or live-library claims. The parent owns the full integrated suite after merging.
