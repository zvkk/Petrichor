# 02 — Mac refinement, Preview and exports

Status: draft for review. Governing requirements: [Connected Crate](README.md). These are three independently deliverable changes: naming/refinement, Preview, and export formats. None introduces Mac Digging.

## Naming and refinement

Use **Crates**, **New crate**, **Smart crate**, **Add to crate**, **Edit crate**, **Delete crate** and **Export crates** for user-facing music collections. Keep internal `Playlist`, `Sections.playlists`, database names, UUIDs and notification identifiers unchanged. Preserve authored user collection names, built-in names and radio **Collections**. Import/export explanations may say **M3U playlist** to identify the external format.

Update the existing toolbar tab, menus, sidebar helpers, editor headers, selection prompts, help text and accessibility labels together. This is a label/consistency pass, not a navigation rearrangement. Keep Home, Library, optional Folders, current search, existing filters/columns and player modes. Preserve default artwork/metadata composition, row density, menu ordering and keyboard commands; additions go adjacent to the related current action.

Use `CrateStyle` and immediate component neighbours for new text, icons, controls and sheets. Quiet connection/availability metadata must not obscure title, artist, duration or row actions. A shared crate detail stays recognisably the current Mac detail view. Native menus remain native; do not replace them with a custom phone popup. No decorative accent, grayscale art, oversized cards or global motion rewrite.

Before editing, capture the existing Mac screen/state inventory identified in the master spec. Compare with identical data, split widths and selected rows after the change. Selected text/action icons must remain legible in all appearance modes and while the window is inactive. Preserve text-entry focus, cancellation, VoiceOver labels and reduced-motion behavior.

## Preview: explicit single-track audition

Add **Preview** next to Play in the existing track context menu and Playback menu. The menu command has an initial shortcut **Option–Return**, active only for a single selected playable local track while no text input/editor has focus. Disable it for radio entries, while a radio source is loaded, for missing audio and for multiselection. Normal Play, Space, Previous and Next retain their current semantics outside Preview.

Preview uses the current engine/player dock. On entry capture the ordinary local queue, cursor, origin, modes, position and playing/paused intent; pause it and create a separately owned single-track audition. Do not mutate the saved ordinary queue or shared crate. Show a small **Preview** label and **End preview** action in the existing player metadata region, retaining the 110pt dock and transport positions.

Use the phone arithmetic: default start `round(clamp(duration × 0.2, 20, 75))` seconds. If duration is unknown/nonfinite/nonpositive, or the result leaves fewer than five seconds, start at zero. Store configurable fraction/min/max locally under existing Playback settings; validate fraction 0–1, finite nonnegative bounds with min ≤ max. Use actual decoded duration for final clamping.

Wait for the intended engine entry to be ready, seek once, then play. A delayed seek must verify source/entry identity and operation generation; track replacement, cancellation or newer Preview invalidates it. Never apply an old seek to the currently playing replacement. Repeated previews replace only the audition, retaining the original ordinary snapshot.

Play/pause and seeking control the audition. Preview Previous/Next are disabled. EOF pauses the audition rather than advancing the saved queue; **End preview** returns to its captured ordinary track/context paused, with its position preserved. Explicit normal Play replaces Preview and discards the captured restore intent; subsequent stale callbacks cannot restore over that new session. If the ordinary track is unavailable on exit, show the normal recovery state without auto-skipping to another recording.

Auditions do not increment play count, update last-played, emit Last.fm Now Playing/scrobbles, enter handoff or persist as the ordinary session restored after relaunch. Gate these signals by actual engine-entry playback purpose, not the visible title or a global flag that could credit a stale finish. Favourite and Add to crate remain deliberate ordinary edits even during Preview. Closing an audition preserves the last ordinary session record.

Existing Mac `PMPlayback.playTrack` replaces the queue, and EOF currently records completion unconditionally. Consequently Preview requires an explicit playback-purpose/session boundary; calling normal Play followed by seek is insufficient. Preserve gapless/crossfade and ordinary EOF crediting for non-preview entries.

## Text and Rekordbox exports

Keep M3U. Add **Copy tracklist**, **Save tracklist…** and **Export to Rekordbox…** in the current crate menu/export sheet. Use the current native save-panel and feedback style; no new export screen. Text options are numbering (on by default) and label inclusion (off by default). Output follows the phone formatter: `01. Artist — Title [Label]`, with label brackets only when enabled/nonempty, fallback `Unknown Artist`/`Untitled`, and three-digit numbering at 100 or more entries.

Manual crates export a fresh snapshot of canonical saved member order, regardless of temporary table sorting/shuffle. Smart crates resolve their current membership once at export start. A running export retains that immutable snapshot even if the live collection changes. Include Unicode/escaped names, allow cancellation without writes, and report per-file failures when exporting several crates.

Rekordbox XML references real local audio file URLs and verified metadata: title, artist, album, genre, label, key, BPM, duration, track/disc/year and available technical fields. Use actual sample rate/file size rather than copying the phone export's current hardcoded placeholders. Escape XML and file URLs correctly. Export does not contain audio or rewrite tags, Rekordbox databases, cue points or beat grids.

Unavailable items produce an explicit list and **Cancel** or **Export available tracks**; the latter displays the resulting count before writing. Do not silently omit them or create unusable local paths. Empty snapshots produce an explanatory message. Exporting a regular shared crate does not modify its wire membership or sharing state.

## Owners and acceptance

| Area | Existing owner |
| --- | --- |
| Labels/actions | Mac `Models/Enums/Sections.swift`, `Views/Components/PlaylistMenuBuilder.swift`, `Views/Components/TrackContextMenu.swift`, playlist sheets and localized resources. |
| Playback | `Managers/Playlist/PMPlayback.swift:14`, `Managers/PlaybackManager.swift:338` and `:919`, `Managers/PlaybackQueueMirror.swift`, `Application/PlaybackSessionStore.swift`. |
| History/scrobbling | `Managers/Playlist/PMTrackUpdate.swift:102`, `Managers/ScrobbleManager.swift:85` and `:98`. |
| Export | `Managers/Playlist/PMImportExport.swift:314`, `Views/Playlists/Sheets/ExportPlaylistsSheet.swift`; phone `src/export/tracklist.ts:15`, `src/export/rekordbox.ts:83` are behavior references, not native path/metadata implementations. |

Acceptance: naming and native screen comparison; shortcut conflicts/text focus; long metadata and minimum windows; short/unknown-duration auditions; rapid Preview/Play/Next/Cancel, seek failure and stale EOF; exact ordinary queue/position preservation; no audition history/scrobbles; audible ordinary gapless playback; text outputs at 0/1/99/100+ entries; XML URL/escaping/missing-file cases; real import and playback in the user's Rekordbox. Source tests do not replace audible or export-application checks.
