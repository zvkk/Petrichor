# 03 — Add Mac-only tracks to shared music

Status: draft for review. Planning assumption: explicit selected-file publication, not a watched-folder uploader. Governing requirements: [Connected Crate](README.md).

## Outcome and entry point

A track already in the Mac library can be copied into the paired shared collection and become discoverable/downloadable on iPhone. The original file remains intact and its existing Mac identity, memberships and playback remain usable. This operation is distinct from sharing crate metadata.

Add **Add to shared music…** to the existing Mac track context menu and File menu, supporting explicit selected tracks. If disconnected/unpaired, offer **Set up connection…** in the existing settings. Never automatically upload an imported folder, or treat sharing a crate as consent to upload its audio. The crate's missing-track details can offer this same explicit action for its listed local-only members.

Use one native confirmation sheet: selected titles/count, total known bytes, paired destination folder, and collision/unsupported-format warnings. Primary action **Add N tracks**; secondary **Cancel**. Show file-by-file progress through the existing activity/notification surface, with Retry/Cancel and a durable result list. No extra player, sidebar or standalone transfers screen.

## File and identity contract

Publish original audio bytes without conversion or tag editing. Read only explicitly selected accessible files. Acquire the required existing security-scoped access, keep a stable read/copy snapshot and verify the source did not change during capture. A changing/recording file is not published; offer retry once its write is complete.

Files already under the paired Mac music root retain their relative path. Files outside it require a confirmed copy into that root first; preserve the original and all source memberships. Store a verified publication mapping between the original native track and the paired copy's real Dropbox file ID/content hash. Canonical/duplicate reconciliation must preserve both physical source identities; no filename or format-based merging.

Validate destination components against the paired root and reserved `.crate-sync` subtree. Never publish under sync metadata, escape the music root, follow a symlink outside an authorized source, or infer the account root after an error. Dropbox App Folder access stays inside the explicitly paired application folder.

Use no-overwrite publication. If a destination path exists, verified equal bytes may reuse its ID; different bytes require a new user-approved name or cancellation. Do not overwrite a different recording, silently autorename, substitute another encoding, delete the source, or delete remote files to repair a failed upload. The same recording title in WAV/FLAC/M4A is not proof of duplicate content.

Use bounded-memory streaming/chunked provider upload for large files, durable resumable operation state and bounded concurrency. An upload journal records source snapshot identity, destination relative path, provider operation/session identity and final verified file ID/hash. Tokens are excluded. Finalization retries first inspect the exact destination rather than uploading another copy. Cancellation retains the local source and reports any provider-confirmed completed item; abandoned incomplete uploads are not presented as completed music.

Completion requires remote metadata/file identity plus content-hash verification of the exact published bytes. A local Dropbox client path existing, a transfer callback or a filename is insufficient. Persist the verified mapping before unblocking crate intents. If the selected native source subsequently changes bytes/path/identity, invalidate its publication proof and reverify; do not publish stale crate mappings.

## Phone availability and recovery

The phone's existing Dropbox ingestion discovers published audio while active. Show **Available to download**, **Downloading**, **Downloaded**, or an actionable failure using its current library/provider patterns. A shared crate can arrive before its audio: keep membership/order and missing counts until normal ingestion resolves the file. Do not mark a transfer done merely because its crate appeared.

Do not eagerly download the entire library. Retain the phone's existing wanted/offline rules and explicit download choices. Unsupported/unplayable audio is reported for that specific file after actual decoder validation; never promise phone playback based only on a file extension. Publication does not change local offline-retention settings or require simultaneous playback.

Source-path movement, app restart, network loss, quota/auth/root failures and cancelled operations retain journals and useful recovery. A failed item cannot block already verified independent items. A summary identifies **Added**, **Already shared**, **Needs a new name**, **Source changed**, and **Failed** individually; the user's original music is never removed.

## Owners and implementation seam

Reuse Mac pairing/auth/root verification and mapping in `Managers/PlaylistSync/DropboxPlaylistSyncCoordinator.swift`, `DropboxPlaylistTransport.swift` and `DropboxPlaylistMapping.swift`. Add a separate audio-publication service/journal rather than widening immutable JSON-upload methods to accept arbitrary media. Native track menus own commands; the existing activity surface owns progress. Phone uses current `src/storage` ingestion/download/media-claims owners, not a second scanner.

## Acceptance

| ID | Required result |
| --- | --- |
| A1 | Selected Mac-only audio appears on phone and actually plays; original source/hash/memberships remain intact. |
| A2 | Large files use bounded memory; restart/retry finalization produces one verified destination, not duplicates. |
| A3 | Existing identical bytes reuse verified identity; different-content collision cannot overwrite either file. |
| A4 | Outside-root sources are copied only after confirmation; reserved paths, traversal and unsafe symlinks are rejected. |
| A5 | A changing source, unavailable bookmark, failed hash, unsupported decode or quota/auth failure reports the exact item and preserves data. |
| A6 | A previously blocked crate becomes syncable only after verified mapping; audio arrival never invents a membership edit. |
| A7 | Cancel, disconnect and partial success have truthful summaries, retain originals and cause no automatic deletion. |

This milestone has its own real-account/file/device gate after crate sync. The current v1 implementation does not already upload audio.
