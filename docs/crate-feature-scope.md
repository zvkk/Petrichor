# Crate Mac — feature and connection scope

Date: 2026-10-10. Status: scoping only; no implementation authorized by this document.

## Intent and constraints

Use Petrichor Dev, now called **Crate Mac** for this project, as the native macOS home for useful Crate capabilities. This is the working name; the installed binary has not yet been renamed. Preserve Petrichor's layout, navigation, player, visual language, and established interactions. Proposed feature controls are additive entries in existing menus, settings, playlist views, and dialogs. This interpretation needs confirmation if “no UI/UX changes” means literally no new controls.

Confirmed direction: the first connection must bring existing Mac playlists to Crate iPhone, and support edits syncing both ways. This supersedes the earlier feature-first and iPhone-to-Mac manual-transfer proposals. Scope the connection first; exports, preview and inbox features follow it. See [Mac-first playlist sync](crate-mac-playlist-sync-scope.md).

Keep Petrichor's Swift/SwiftUI application, SQLite/GRDB storage, and Crescendo playback engine. Translate selected Crate behavior into native services and reuse its test scenarios; embedding the React Native app or replacing the player is unnecessary for this scope.

## Verified baseline

- Petrichor: clean `dev/local-customizations`, `27ffcc5d62635e4d1647398d720ef895b029eb53` before this document. Dev and Stable have separate installed identities; their music source files may be shared.
- Crate: inspected local `origin/master` at `aa61de5`. This is a locally recorded release reference, not a freshly fetched remote check. The parent checkout is an older, dirty planning branch; local `master` is also older. Neither checkout was changed.
- Personal product reference: `Documents/My Ideaverse/Efforts/Music App/App Design - Crate.md`, especially the own-files → preview/sort → ordered crates → DJ export loop. These notes are intent, not proof of implementation.

Petrichor already implements manual and smart playlists, multiple playlist membership, ordering, favourites, local scanning, duplicate handling, discovery, playback history, M3U import/export, and native playback/queue controls. It stores BPM, imported rating and extended metadata including key and label. These do not all appear as table columns or smart-rule fields.

Crate implements triage decisions and Undo, intro-skip previews, manual ordered crates, Rekordbox XML/text exports, daily resurfacing, cloud audio ingestion, and offline downloads. Its smart-crate rules exist in the backend, but no production caller of the smart-crate creation API was found. Do not describe its smart-rule authoring as a shipped screen.

## Feature candidates after the connection

| Order | Capability | Fit within Petrichor | Rough engineering effort |
| --- | --- | --- | --- |
| 1 | Copy/export text tracklist | Add a playlist menu action and text format to existing export controls; preserve saved playlist order; optional numbering and label | 4–8 hours |
| 2 | Rekordbox XML export | Extend existing playlist export with XML; use actual Mac file URLs, available metadata and saved track order | 1–2 days |
| 3 | Intro-skip preview | Add Preview to the existing track menu and a keyboard command; use current player with a one-shot start offset | 1–2 days |
| 4 | Unsorted inbox with Keep/Dismiss/Undo | A managed playlist displayed using the current playlist/table view; commands in existing menus; persistent sorting state | 3–5 days |
| 5 | DJ-focused smart playlist rules | Extend the existing rule editor with BPM range, lossless and rolling date rules; optional key support and opt-in table columns later | 2–3 days |

Estimates are planning ranges for one engineer including focused tests and local acceptance, not delivery promises. Playback behavior, real-file metadata coverage, or export interoperability may extend them. One day means approximately 6–8 focused engineering hours.

### 1. Text tracklists

Output `01. Artist — Title`, optionally including label. Copy to clipboard or save `.txt` from existing native controls. Snapshot resolved smart-playlist membership before exporting. Use canonical saved order for manual playlists; do not silently substitute a temporary table sort. Handle empty playlists and write failures explicitly.

Acceptance: correct order after manual reorder; Unicode, missing tags, 100+ rows, duplicate names, clipboard and save cancellation/error paths.

### 2. Rekordbox export

Export selected playlists with their local audio references and known BPM/key/label values. Preserve M3U as an available format. Validate paths and report unavailable tracks; never imply the XML includes the audio. Reuse Crate's format intent and cases, but do not copy its placeholder sample rate, play count or other hardcoded metadata where Petrichor has real values.

Acceptance: escaped names, spaces/non-ASCII in file URLs, smart/manual order, missing files, distinct same-named files, and import/playback of exported tracks in the user's Rekordbox installation. Generated XML tests alone do not establish interoperability. This is playlist export, not Rekordbox database sync, cue-point or beat-grid transfer.

### 3. Preview

Crate's default start offset is 20% of duration, bounded to 20–75 seconds, with fallback to the beginning when insufficient audio remains. Port this as explicit preview playback rather than changing normal Play. This is time-based intro skipping, not audio analysis or drop detection.

Use Petrichor's existing readiness and seek lifecycle. Specify how Preview takes over the player and queue before implementation; the minimum proposal is an explicit single-track audition through the existing player, without background restoration or automatic timed snippets. A preview must not apply a delayed seek to a subsequently selected track. Saved preview settings should actually feed the command.

Acceptance: short/unknown-duration tracks, rapid Preview/Next/Pause, manual seek, track replacement, end of track, and audible checks. Decide whether auditions count towards history/scrobbling; recommended default is to exclude explicit auditions from those signals.

### 4. Unsorted inbox

Store sorting state separately from favourites, play counts and playlist membership. Show it as a managed playlist with Petrichor's ordinary rows. Proposed commands: Keep in Playlist, Mark Sorted, Dismiss from Inbox, Return to Inbox, and Undo.

Keep writes the decision and new playlist membership together. Undo reverses only membership created by that decision. Dismiss affects sorting state only: source files remain on disk, available in the library and existing playlists. This is deliberately adapted from Crate's archive behavior because the Mac file may be the original shared by other apps.

On enablement, baseline the existing collection as already sorted; new imports enter the inbox. Users can return selected older tracks to it. Repeated scans must not reset decisions. An inaccessible folder must not be treated as a successful empty scan. No automatic advance or replacement of ongoing playback in the first increment.

Acceptance: repeat scans, restart, duplicate/format reconciliation, deleted playlist, rapid commands, failed transaction, batch actions, and Undo with an existing membership. Decide how missing/reappearing or moved files retain their sorting identity during implementation design.

### 5. Smart playlist extensions

Reuse Petrichor's existing rule authoring/evaluator. Add BPM bounds, lossless, and relative date-added rules first; existing genre, play-count and date fields already cover much of Crate's rule model. Key matching needs verified parsing/normalization before promises about harmonic compatibility. Missing BPM/key remains unknown; no analysis engine is included.

Optional BPM/key table columns belong in the current column chooser and stay off by default. Key display and harmonic rules are extensions inspired by Crate's stored data, not a direct port of an already implemented Crate UI.

## Suggested releases

1. **Connection:** existing Mac manual playlists appear as iPhone crates; names, membership and order sync both ways. Mac-to-iPhone is the first acceptance case, not permanent Mac ownership.
2. **Export:** text tracklist plus Rekordbox XML.
3. **Audition and sort:** Preview, followed by the inbox and transaction-safe Undo. Ship preview independently before adding the workflow state.
4. **Refinement:** DJ smart rules and optional metadata columns. Rediscovery tuning is lower priority because Petrichor already has discovery and unplayed selections.

Keep the user-facing term “Playlist” for this phase. A Crate manual crate maps conceptually to a Petrichor regular playlist; this does not imply their IDs, schemas or databases are interchangeable.

## Cross-device integration boundary

Crate's inspected storage-provider interface authenticates, lists audio and downloads files. Its crates, decisions and history live in local SQLite. No implemented portable app-data manifest or phone/desktop state replication was found. Sharing the same cloud music folder does not share playlist membership or ordering.

Selected approach: a shared, versioned playlist synchronization layer with stable identities, offline changes, conflict handling and explicit deletion records. Both apps remain independent local applications. Their local database schemas are not interchangeable.

Earlier alternatives (standalone Mac features first, or one-way iPhone-to-Mac import) are superseded. The user selected Dropbox. The connection scope defines the proposed Dropbox transport and concurrent-edit handling; verify the real account, music-root mapping and app permissions during setup. Do not promise a delivery estimate from the export estimates above.

For transfer, do not match by filename alone or synchronize live SQLite files. Persist source identities alongside local row IDs so later transfer can be added without assuming a Mac integer ID equals an iPhone provider ID. Existing cloud clients can provide local audio folders, subject to availability and sandbox access; native provider OAuth/download management can wait.

Defer a replacement UI, swipe-card screen, automatic BPM/key analysis, automatic metadata enrichment, audio-tag writeback and a statistics dashboard. Add only the account/folder setup and sync feedback required by the selected connection transport within existing settings and dialogs.

## Source pointers

Petrichor paths at the baseline above:

- `Managers/Playlist/PMRegularPlaylists.swift:227` and `:311`: membership and manual order.
- `Views/Components/TrackContextMenu.swift:273`: existing Add to Playlist; `Views/Components/PlaylistMenuBuilder.swift:7`: playlist actions.
- `Managers/Playlist/PMImportExport.swift:315`, `Views/Playlists/Sheets/ExportPlaylistsSheet.swift:3`: current M3U export and sheet.
- `Managers/PlaybackManager.swift:338`: seek; `:778`: playback readiness callback.
- `Models/Core/FullTrack.swift:36`, `Models/Core/ExtendedMetadata.swift:31`, `Managers/Database/DMMetadata.swift:34`: metadata storage and ingestion.
- `Models/Core/SmartPlaylistField.swift:25`, `Managers/Database/DMSmartPlaylistQueries.swift:161`: existing rule fields and evaluator.
- `Managers/Database/DMDiscoverQueries.swift:323`: existing never-played selection.

Crate paths must be read with `git show aa61de5:<path>` rather than the stale working tree:

- `src/triage/preview.ts:19`, `src/triage/index.ts:63`, `src/library/triage-decisions.ts:37`: preview and triage contracts.
- `src/library/crates.ts:14`, `src/library/smart-crates.ts:25`: ordered crates and rule capabilities.
- `src/export/tracklist.ts:18`, `src/export/rekordbox.ts:54`, `src/export/index.ts:21`: exports and URL resolution.
- `src/storage/types.ts:77`, `src/library/db.ts:16`: audio-provider interface and local database.
- `src/library/daily-picks.ts:126`: persisted daily resurfacing.

This is a source-based feasibility assessment. No application code, database or installed app was modified; no runtime acceptance tests were performed for these proposed features.
