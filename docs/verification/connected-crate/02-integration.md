# Plan 2 integrated verification — 14 October 2026

Source implemented and ready for code review. Live acceptance remains open. PR: https://github.com/zvkk/Petrichor/pull/2, stacked on Plan1 PR1. Verified production source: ee9315ce33f9fdf38ed068eb29ed32ab5ad92ffb, including parent localization66fe219. Subsequent receipt changes are documentation only. No installation, phone changes, merge or release performed.

Crate naming now covers existing collection controls and automation display text without changing identifiers, authored names, radio Collections or legacy Siri phrases. Preview uses one engine, entry-owned purpose and one captured ordinary context; End restores paused. Export snapshots preserve saved order and unresolved members; native text/XML actions share explicit availability decisions. The Mac layout, original-colour artwork and110pt dock remain source-level constraints; rendered equivalence has not been established.

## Primary verification

- Full native XCTest: **64 total:63 passed,1 existing optional skip,0 failures**. The skip is FolderRefreshTests.testCopiedLibraryRefresh, which requires a supplied backup. Result: `/private/tmp/connected-crate-baseline/Logs/Test/Test-Petrichor-2026.10.14_18-47-36-+1100.xcresult`; log `/private/tmp/crate-plan2-integrated-final.log`.
- Built app/test host identity independently verified as `org.Petrichor.zak.plan2-verification`; embedded test bundle unchanged. `codesign --verify --deep --strict` passes. Tests run with an isolated host, not the installed development identity.
- Canonical protocol fixture temporary copy SHA-256 `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5` verified. Protected Desktop fixture prompt avoided through the existing test-only override.
- Pinned SwiftLint0.63.3: **11 inherited errors remain,0 introduced errors**, compared by file/line/rule/reason against Plan1 baseline. Full lint therefore remains failing; this is not a clean-lint claim. Existing findings lie in Plan1 sync sources/protocol, not new Plan2 export/Preview files.
- String catalog:825 prior payloads unchanged,29 new entries across the parent/fix range; native symbol generation/build succeeds. `git diff --check` passes.

Command:

```sh
TEST_RUNNER_CRATE_SYNC_FIXTURE_PATH=/private/tmp/crate-plan2-integration-fixture.json \
xcodebuild test -project Petrichor.xcodeproj -scheme Petrichor \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/connected-crate-baseline \
  -clonedSourcePackagesDirPath /private/tmp/petrichor-build/SourcePackages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  'PETRICHOR_APP_NAME=Crate Mac' PETRICHOR_BUNDLE_ID=org.Petrichor.zak.plan2-verification \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none
```

## Standards

Initial isolated review found3P2 issues: unbounded entry/Track retention, nonlocalizable export errors/format labels, and quadratic main-actor restoration. All addressed in the one final fix wave. Lifecycle regressions cover30 rebuilds of a2,000-row queue, artwork-free callback records, late ordinary/Preview EOF and a gapless successor replaced before its UI callback. Restoration uses lookup indexes while preserving occurrence order and deliberate edits.

## Spec

Independent review found no further confirmed source defect, while identifying the unobserved acceptance gates below. Primary/merger also found missing OS metadata cleanup, Fresh Music focus provisioning and remaining visible naming/localization/introduced lint issues. All six final finding groups were addressed together. Exactly one scoped rereview of0753f97..ee9315c confirmed them addressed and found no new important fix-diff breakage.

## Open acceptance gates

- Native comparison with identical data at1200x800 and1100x600, Light/Dark/Auto and inactive selection; long metadata, VoiceOver, focus and reduced motion. Before-edit source-baseline captures were not obtained and cannot be claimed retroactively. The installed skin remains available as a separate comparison reference.
- Real Option–Return/context Preview across table/Fresh Music, editable focus/multiselect/radio/missing media exclusions, rapid replacement/cancellation, real decoder failure, live Last.fm/relaunch and audible ordinary gapless/crossfade.
- Actual Copy/paste/save content/options, panel cancellation without output, unavailable-item list/count choice and multi-crate errors through native UI.
- Import generated XML into the user's Rekordbox and play referenced tracks. XMLParser/real48kHz fixture tests do not establish this. Wire format was checked against [official developer support](https://rekordbox.com/en/support/developer/?lang=en) and its [XML format table](https://cdn.rekordbox.com/files/20200410160904/xml_format_list.pdf).

Naming, Preview, text export and Rekordbox export retain their separate live gates. Plan1 two-device acceptance remains separately open in central issue83. Plan3+ remains outside this delivery.

## Test-host correction

The export worker's first executed test omitted the host override and selected the existing development container. The log showed session restoration/preparation. Primary read-only checks found the installed app process unchanged, SQLite integrity intact, and DB/WAL/session timestamps predating that test; no persisted library/session writes were detected. No pre-test hashes existed, so byte identity is not asserted. No repair was attempted. Correctly isolated final worker and primary tests are the accepted verification evidence; detailed account remains in02-exports.md.

## Follow-up review fixes — 14 October 2026

Fixed the confirmed End-preview/Play race: Play/Pause intent is retained while the ordinary entry reloads, consumed after a successful restore seek, and discarded on replacement. Added regression coverage for immediate Play, Play then Pause, failed seek, and replacement during seek. Preview engine transitions now live in cohesive PlaybackManager operations; PreviewSettings owns the preference keys, defaults, persisted reader and validation used by playback/settings. Three export count messages now use catalog plurals, including count-driven substitution for the message containing a crate name.

Full native test build: 69 passed, one existing optional skip, zero failures (70 total). Log: `/private/tmp/crate-plan2-review/fixes-tests.log`. Compiled English catalog runtime checks passed for counts 1 and 2 across all three corrected messages. Pinned SwiftLint remains at the same 11 inherited errors; none introduced. Catalog comparison confirms only the three intended payloads changed. `git diff --check` passes.

No installation or live acceptance performed. The native visual, audible, interaction and Rekordbox gates above remain open.
