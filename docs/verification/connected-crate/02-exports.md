# Plan 2 text and Rekordbox export source verification

14 October 2026. Source implementation receipt; native owner and Rekordbox acceptance remain open.

Implemented immutable export value snapshots, fresh saved regular-crate membership order, one smart-rule evaluation per export, explicit shared unresolved slots, text numbering/label options and native Copy/Save feedback. Existing export sheet offers M3U, text and Rekordbox XML; failures are reported per crate/file. Filenames that sanitize identically receive deterministic suffixes within a bulk operation.

Snapshot metadata comes from saved FullTrack values and the existing read-only MetadataEngine. Available audio gets a verified regular-file URL, measured size and decoded sample rate/bitrate. Missing files retain display metadata for text; unresolved entries without display metadata and audio-dependent formats require the native unavailable-items decision. Cancel returns before an output write. Export has no tag/audio/database mutations.

XML uses the Rekordbox `DJ_PLAYLISTS` structure, stable collection/reference IDs within an export, ROOT folder Count, escaped Unicode attributes, locale-independent numbers and percent-encoded `file://localhost/` URLs. Bitrate is Kbps from the existing reader; sample rate is Hz.

## Observed checks

- Formatter red: native compile failed on absent ExportTrack/TracklistFormatter (`/private/tmp/crate-exports-red.log`).
- XML dependency red: build-for-testing failed on absent RekordboxExporter in the production writer (`/private/tmp/crate-exports-xml-red.log`).
- Final full native XCTest target: **45 tests, 1 skipped, 0 failures**; xcresult `/private/tmp/crate-plan2-exports/Logs/Test/Test-Petrichor-2026.10.14_18-25-02-+1100.xcresult`; log `/private/tmp/crate-exports-full-final.log`.
- Production capture test checks saved order against sorted cached rows, live edits after capture, shared unresolved members with unchanged wire state, fresh smart membership and a real PCM WAV whose decoded 48000Hz overrides a deliberately stale stored 44100Hz value.
- XMLParser test checks Unicode/space/ampersand local filename, XML escaping, exact resolved path, collection/reference IDs, measured byte size and 48000Hz.
- Writer test checks saved UTF-8 content, missing-media XML rejection without an output file and per-file destination errors.
- Native app compiled by xcodebuild test; `codesign --verify --deep --strict` passed. Built host identity checked as `org.Petrichor.zak.plan2-export-tests`.
- `git diff --check` passed.

Final command (executed outside nested sandbox because SwiftPM sandbox initialization was denied):

```sh
TEST_RUNNER_CRATE_SYNC_FIXTURE_PATH=/private/tmp/crate-plan2-export-fixture.json xcodebuild test \
  -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/crate-plan2-exports \
  -clonedSourcePackagesDirPath /private/tmp/petrichor-build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none \
  'PETRICHOR_APP_NAME=Crate Mac' PETRICHOR_BUNDLE_ID=org.Petrichor.zak.plan2-export-tests
```

Temporary fixture is byte-identical to `docs/fixtures/dropbox-playlist-protocol.json`: SHA-256 `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5`. First full-suite attempt with the protected Desktop fixture paused at testSharedWireFixtures; it was interrupted and rerun with this temporary copy.

## Test-host identity correction

The first executed native test command omitted PETRICHOR_BUNDLE_ID and therefore ran the derived Debug test host under `org.Petrichor.zak.debug`. Its log showed ordinary session restoration and preparation paused at an existing saved position. This was an isolated derived binary, but its identity selected the existing development app's data container. No installed app was installed or explicitly launched. The primary agent independently checked existing app process/state and reports unchanged pre-test DB/WAL/session timestamps plus SQLite integrity; its private receipt is `connected-crate-plan-2/mac-state-readonly-check.json`. No restore/repair was attempted. Final verification uses the separate host identity above; embedded XCTest bundle retains its existing `org.Petrichor.tests` identifier.

## Acceptance still required

- Actual native Copy result/paste and saved text review through the menus/sheet.
- Native save-panel cancellation with direct filesystem observation, unavailable-items Cancel/Export available interactions and exact resulting count.
- Multiple-crate destination errors through the actual native sheet.
- Normal/minimum-window, VoiceOver, focus and appearance comparison for export additions.
- Import produced XML into the user's Rekordbox and play referenced tracks.

No installation, release, user-audio modification, tag writing, Rekordbox database writing or live Rekordbox import was performed.
