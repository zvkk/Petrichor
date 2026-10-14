# 01 — Connected collection and regular crates

Status: draft for review. Governing requirements: [Connected Crate](README.md).

## Outcome

An explicitly shared ordinary Mac crate appears on iPhone with the same identity, name, membership and order. Edits on either client converge after a successful foreground sync. Each app plays its locally available or downloadable copy of the matched recording. Existing unrelated crates and local music are preserved.

## User flow and native presentation

Use Mac **Settings → Integrations → Crate connection**, refining the existing Dropbox group rather than adding a screen. Show **Connect Dropbox**, **Choose music folder…**, **Sync now** and **Disconnect**. Pair the remote music folder and its matching local Mac folder through the current native picker. On phone use its existing provider/settings shell with the same terminology. Show the selected human-readable folder and connection state; put root IDs/redirect/debug information under **Details**.

Share a regular crate through its existing options menu: **Share with iPhone** on Mac and **Share with Mac** on phone. Sharing is explicit per crate. Newly created unrelated crates stay local until shared. Received crates retain shared identity; same-named local collections are not merged. Built-in, radio and smart collections are ineligible for this v1 action.

Add a quiet shared-state indicator to the existing crate header or adjacent metadata; selecting it opens a small native details sheet. No extra sidebar, toolbar tab or player control. State wording:

| State | Copy and action |
| --- | --- |
| No connection | **Connect Dropbox to share this crate**; open existing settings. |
| Paired, unshared | **Share with iPhone/Mac**. |
| Local intent or unsent revision | **Changes waiting to sync**; local editing remains available. |
| Active operation | **Syncing…**. |
| No pending obligations/conflicts | **Crate synced**; audio availability is a separate count. |
| Mapping/unavailable audio | **N tracks unavailable on this device** or **N tracks need adding to shared music**; show exact affected items. |
| Conflict | **Changes on both devices**; **Review changes…**. |
| Auth/root problem | **Reconnect Dropbox** or **Check music folder**; retain all pending edits. |

Conflict resolution uses existing-style sheets: show each version's name and ordered tracks, identify device and differences, and offer **Use Mac version**, **Use iPhone version**, or **Keep both**. Handle delete-versus-edit in the same sheet. Recheck heads before committing a choice; refresh if it became stale. Device names help recognition, not revision precedence.

Deleting a shared crate uses the existing destructive confirmation with explicit copy that the crate will be removed on both devices and music files remain. Disconnecting stops transport and retains local/shared state and pending edits. An unshare/detach action is not added to v1.

## Data and integration requirements

Preserve [the complete v1 contract](../../../dropbox-playlist-protocol.md), including its explicit App Folder `/` mode, parent limits, aliases, unresolved positions, tombstones, integrity checks, conflict resolution chains and exact-byte retries. Verify the same account/root/library before writes. Never pair by a path label alone or fall back to another root after a generic failure.

Import the existing phone sync feature forward into the newest accepted iPhone source. Do not check out or install its older app UI. Integrate codecs, transport, storage, lifecycle, settings and transactional capture with the current library/media-claims/mutation contracts.

**Migration requirement:** old sync migration 11 creates three `playlist_sync_*` tables; newer iPhone migration 11 creates Digging/token tables, and migration 12 repairs that newer schema. Historical migrations stay unchanged. Append a new migration after the target's actual latest version to create/validate the sync tables without replacing existing rows. Validate table shape as well as existence. Unknown shapes fail safely with recovery information rather than dropping/rebuilding data. Migration and version checkpoint commit atomically.

Migration fixtures must cover fresh databases, ordinary old databases, old sync v11, current v12, old-sync upgraded through the existing repair, and deliberate incompatible table shapes. Preserve pairings, exact queued revision bytes, download obligations, aliases, media, crates, favourites, session rows and ownership tokens. Reopening the upgraded database must be idempotent; injected failure must leave the previous version and data recoverable.

Capture every explicit shared-crate edit in its owning transaction, including ordinary editor/create/rename/delete/add/remove/reorder, queue-created crates/bulk additions, existing iPhone triage, Browse Digging and rule-based Digging Add/Undo. Only a successful ownership-checked Undo removes shared membership. Merely skipping a phone Digging track does not generate a crate removal. Canonical promotion, scanner removal and format reconciliation update local projection/aliases without fabricating user deletions or dropping wire members.

Persist unsent intent before acknowledging a local save. Materialize only a still-current generation after asynchronous mapping. Incoming changes invalidate stale editors; Cancel remains write-free. Use stable Dropbox file ID plus verified content/location mappings. Newly originating local-only or non-Dropbox tracks block full publication of that crate; do not silently send a shorter list. Known remote references unavailable locally retain their identity/order and visible missing count. Unrelated crates continue syncing when one is blocked.

The coordinator admits local commands immediately and schedules a debounced attempt while active, retaining the existing approximately 400–500ms platform debounce. Sync on activation, explicit retry and accepted edits; do not promise delivery while iPhone is suspended/closed. Recover cursors durably; bounded retries do not spin on auth, root, permission or integrity failures.

## Existing owners and verification locations

| Owner | Verified source location |
| --- | --- |
| Mac lifecycle/settings/actions | `Managers/PlaylistSync/DropboxPlaylistSyncCoordinator.swift:25`, `Views/Settings/DropboxPlaylistSyncSettingsView.swift`, `Views/Components/PlaylistMenuBuilder.swift:32`. |
| Mac protocol/store/mapping | `Models/PlaylistSync/PlaylistSyncProtocol.swift`, `Managers/PlaylistSync/PlaylistSyncStore.swift`, `Managers/PlaylistSync/DropboxPlaylistMapping.swift`. |
| Old phone capture/editor | iPhone sync `src/library/playlist-sync-capture.ts:29`, `src/library/crate-edit.ts:64`, `src/playlist-sync/use-playlist-sync.ts:8`. |
| Current migrations/writers | iPhone `src/library/schema.ts:197`, `src/library/db.ts:73`, `src/library/crates.ts:309`, `src/library/browse-digging.ts:260`, `src/library/rule-digging-commands.ts:174`. |
| Alias projection | iPhone `src/library/track-lifecycle.ts:37`; existing sync capture retains wire references independently. |

## Acceptance

| ID | Required observed result |
| --- | --- |
| C1 | Pair both clients to one real account/root/library; a mismatched root is rejected without writes. |
| C2 | Share one Mac crate with at least three mapped tracks; phone has exact name/order, and each recording actually plays. |
| C3 | Phone rename, add, reorder and explicit remove return to Mac; repeat in reverse. |
| C4 | Queue-created/bulk-added and current phone Digging membership edits sync; Undo preserves pre-existing and later-owned memberships. |
| C5 | Offline edits survive restart and reconnect; retries/replays create no duplicates or echoes. |
| C6 | Concurrent edits and delete-versus-edit retain both versions until an explicit valid resolution. |
| C7 | Missing audio, alias promotion, moved files and disconnected roots never shorten shared membership or falsely report deletion. |
| C8 | Stale editor and newer mapping generations cannot overwrite incoming state; failed transactions publish nothing. |
| C9 | All migration fixtures preserve data and pending bytes; disconnect/reconnect retains work. |
| C10 | Native Mac layout/interaction baseline remains intact; unrelated phone work and unrelated collections are preserved. |

Completion requires live two-device evidence for C1–C7 as well as source and migration tests. Existing protocol test success alone is insufficient.
