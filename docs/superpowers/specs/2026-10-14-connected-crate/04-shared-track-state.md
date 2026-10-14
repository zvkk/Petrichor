# 04 — Shared favourites and deliberate metadata edits

Status: draft for review. Governing requirements: [Connected Crate](README.md). Requires verified track identity and the v2 extension capability on both clients.

## User outcome and enablement

Favourite a shared track on either client and see that preference on the other. Correct its display tags once and see the same deliberate values in both clients' library, details, player, export and supported smart rules. Device files and audio-engine properties are unaffected.

Add two options within existing **Crate connection** settings: **Share favourites** and **Share tag edits**. Enabling identifies the matched shared collection and requires the other client's supported capability. Do not enroll local-only music or other providers silently.

At first enablement, existing verified favourites seed the shared set as a union of positive selections. A missing local favourite is not an unfavourite event. Each client durably declares its complete bootstrap snapshot against the agreed catalogue generation. Until both snapshots arrive, show Preparing favourites and retain unknown shared states. Once both are complete, seed false only for verified catalogue entries with no positive selection on either client and no newer explicit revision; absence during discovery is never a removal. Live edits captured during bootstrap are preserved and rechecked transactionally rather than overwritten by seeding. Thereafter explicit unfavourite writes a false value with ancestry. Tag edits share **new deliberate edits from enablement onward**; do not treat all imported fields or a row-level historical edit timestamp as per-field user intent. Existing corrections can be published through explicit **Use these tags on both devices…**, listing selected fields before committing.

Add **Edit tags…** to the current Mac track menu/details action area. Open a compact native form over the existing view with Save/Cancel; keep its read-only technical details. Reuse the phone's existing editor. The current Mac detail screen is primarily a display surface, so an editor and partial transaction-safe write path are required rather than assuming it already exists.

## Shared fields and values

| Fields | Wire value and validation |
| --- | --- |
| title | NFC string, trimmed, 1–512 Unicode scalars, no C0/C1 controls. |
| artist, album, albumArtist, genre, label | NFC string, trimmed, 0–512 scalars; empty is an explicit cleared display value. |
| musicalKey | NFC string, trimmed, 0–128 scalars; preserve authored key notation, do not infer harmonic equivalence. |
| bpm | Null for unknown, otherwise finite 0–1000 number; 0 is distinct from unknown. |
| year | Null for unknown or integer 1–9999; adapt Mac string storage explicitly. |
| trackNumber, discNumber | Null for unknown or integer 0–9999. |
| favourite | Boolean; absent record means no shared decision, not false. |

Text fields use the same control exclusions as v1. Payload maximum is 64 KiB per field revision. Unlisted fields are rejected by this feature version, not silently stored. Duration, codec, bitrate, sample rate, channels, filesize, local URI, artwork URI, waveform/analysis, play counts and last-played are not editable shared values.

An edit record explicitly distinguishes **override** from **inherit**. Clearing a string sets an empty override; **Reset to file tags** removes the override through an explicit inherit revision. Null for numeric unknown is not an instruction to delete a track. Cancellation writes nothing.

## Identity, catalogue and conflict contract

Use `(verified libraryId, provider:dropbox, fileId)` as the wire identity. Path components use a deterministic SHA-256 encoding of the UTF-8 file ID, with the full identity verified inside the decoded body. Store aliases/projection separately. Do not treat native UUIDs or a preferred local encoding as a new shared track, or spread edits to a similarly named unverified recording.

The v2 track catalogue stores a versioned agreed base for each explicitly enrolled file ID: verified content hash, normalized source tags, read-only duration/lossless classification, and record ancestry. Initial base seeding explicitly uses verified Mac source tags, not localized Unknown Artist/Untitled display fallbacks; missing tags remain typed unknown values. User overrides remain separate and win. Only same-content records may converge automatically. Different-content or divergent base records require verification/review and retain the last agreed base. Missing base data remains unknown; never synthesize zero or delete a catalogue record because one device cannot see the file. This catalogue supports consistent metadata and later shared smart-rule evaluation.

Each editable field is an independent immutable revision stream with library/track/field/version, revision ID, parent IDs, device ID and typed operation/value. Reuse v1's graph and exact-byte persistence requirements, bounded parent-resolution chains and strict identity validation. Different-field edits merge by independent streams. Sequential same-field edits follow ancestry, not wall-clock time. Identical concurrent field values may converge through a resolution revision covering both parents; different concurrent values require explicit review. Retain every conflicting value and pending intent.

Capture a field change, its local projection and outgoing intent atomically. Incoming projection updates only that field and suppresses echo capture. Do not copy whole `Track` rows between apps. Mac stores shared overrides separately from imported raw tags and updates effective query/cache projections transactionally. iPhone preserves `local_uri`, provider/media fields, aliases and ownership while applying through its mutation/media-claims boundaries. Rescan/canonical-promotion/importer paths retain deliberate overrides and cannot create false user changes.

A metadata editor carries per-field baseline tokens. Incoming changes to a draft's dirty field block its save with **Tags changed on your other device**; retain the draft and offer an explicit compare/resolve. Untouched fields can refresh. A conflict indicator opens a native field-by-field sheet with **Use Mac value** / **Use iPhone value**, retaining the current presentation until resolution. Favourite conflicts use the same explicit semantics and never discard either intent by timestamp.

Caches, album grouping, visible rows, player labels, exports and smart-match projections receive one postcommit invalidation. Do not recreate the player/source or reset scroll/selection merely because a tag changed. Remote favourite projection does not trigger Last.fm love/unlove; existing Last.fm integration remains a local deliberate-action option, preventing cross-device echoes.

## Owners and acceptance

Mac: `Managers/Database/DMTrackUpdate.swift:13`, `Managers/Playlist/PMTrackUpdate.swift:36`, `Views/Main/TrackDetailView.swift:265`, `Models/Core/FullTrack.swift`, `Models/Core/ExtendedMetadata.swift:3`. iPhone: `src/library/favourites.ts:6`, `src/library/tracks.ts:302`, `src/library/track-lifecycle.ts:12` and `:37`, current metadata-edit tests.

Acceptance requires favourite/unfavourite round trips; positive-union bootstrap without accidental removals; no historic imported-tag publication; independent-field merges; same-field conflicts and stale editor rejection; Unicode/null/clear/inherit validation; aliases and source relocation; restart/outbox rollback; rescan preservation; fresh visible grouping/player/export/smart results; unchanged media/provider fields and file hashes; no echo-driven Last.fm changes. Test missing/unmapped tracks before hydration and after later mapping. Then verify real two-device edits and native editors.

Listening-history synchronization and audio-tag writeback are excluded. Future history sharing needs immutable listening events; copying cumulative counts would double-count them.
