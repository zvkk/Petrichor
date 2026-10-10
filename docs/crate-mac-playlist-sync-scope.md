# Crate Mac ↔ Crate iPhone: Mac-first playlist sync

2026-10-10. Product requirements and Dropbox selection confirmed. The design below is proposed; implementation planning remains. No application code changed.

## Confirmed outcome

The user calls the Petrichor Dev-based app **Crate Mac**. Their existing Mac playlists must become crates on iPhone. Both apps must be able to edit shared collections and receive each other's changes. Mac-to-iPhone is the initial population and first acceptance case, not a permanent one-way ownership model.

Preserve Petrichor's interface and use existing playlist/crate screens. Add only necessary connection settings, sync status and recovery dialogs. Do not replace the player or adopt Crate's phone layout on Mac.

## First milestone

Sync ordinary, manually ordered playlists: persistent identity, name, membership and track order. Changes on either device must survive app restart and eventually converge when both apps next run a successful sync. Include creation, renaming, adding/removing tracks, reordering and explicit playlist deletion. Deleting a playlist never deletes its audio.

Start with user-selected Mac playlists. Keep existing iPhone crates and unrelated Mac playlists; do not merge collections because they have the same name. Persistently record selected collection identities. Support publishing a newly created iPhone crate back to Mac, too.

Smart rules, built-in playlists, radio collections, artwork, favourites, history, metadata edits and triage state are outside this first milestone. Smart-playlist rule models differ between the apps. A future snapshot-as-manual-playlist action can be explicit; do not silently convert a smart playlist to an editable shared collection.

## Connection model

Both apps keep their own SQLite databases and players. A transport exchanges versioned playlist data and revisions, with a persistent outgoing queue and received-change tracking. Local edits and their outgoing records must commit atomically. Repeated delivery must be idempotent and must not echo received changes indefinitely.

Do not share live database files. Do not use local database row IDs or absolute Mac paths as cross-device track identities. Playlist UUIDs can seed a namespaced shared identity, with an explicit mapping at each endpoint. Stable track identity needs a verified mapping between Mac files and the iPhone provider's source identities. Relative paths within an agreed music root can help establish that mapping; filename/title alone cannot. Provider hashes must not be assumed to use the same algorithm.

Audio availability is a separate dependency: a playlist manifest cannot make Mac-only audio playable on iPhone. First release should use the same cloud-backed music collection already available to both apps. Existing iPhone audio download behavior can fetch matched cloud tracks. Track entries with unavailable/unmatched audio retain identity and position in sync state and must not be interpreted as deliberate removals when the visible playlist is saved. Surface missing-track counts and recovery through native status/details.

The user selected **Dropbox**. Reuse Crate's existing Dropbox integration on iPhone and add a native Dropbox client to Crate Mac. Confirm the same account and accessible music root on both devices. The local Mac music root `/Users/zakcupido/Desktop/Atlas/Music` and Dropbox's local root `/Users/zakcupido/Library/CloudStorage/Dropbox` exist as distinct directories; this does not establish which files have cloud copies. Supporting automatic upload of Mac-only audio would expand this scope.

Sync on app activation, after edits while active, and via an explicit retry/Sync Now action. Background execution and instant updates while iPhone is closed are not promised.

## Proposed Dropbox transport

Use Dropbox API access on both apps for playlist metadata. Mac playback continues to use its existing local music folders; do not make metadata correctness depend on the desktop Dropbox client's upload timing. No hosted server is needed for this foreground-first design.

Authenticate each device independently with authorization-code PKCE and refresh tokens. Keep credentials in iPhone SecureStore and macOS Keychain. Reuse the existing Dropbox app registration if its access type, account access and registered native callbacks support both apps; otherwise resolve registration compatibility before implementation. The installed token's grants have not been inspected. Required endpoints need appropriate metadata-read, content-read and content-write permissions; reconnection may be required. Never copy tokens between devices or persist them in sync files.

Place a dedicated `.crate-sync/v1` metadata subtree inside the explicitly paired Dropbox music root, with a library identifier that both apps join. Pin account, namespace/root and sync-folder identity; never infer the root from a failed request or silently fall back to the account root. Explicitly exclude the sync subtree from audio ingestion. Keep the old audio-sync API separate from the new playlist-sync API; the existing Dropbox provider currently returns `rootKey: null`, so pairing needs stronger root evidence.

Publish immutable per-playlist revision files addressed by generated revision IDs. Each records protocol version, library ID, playlist ID, parent revision IDs, originating device ID, name, ordered stable track references and an explicit deleted flag. Keep audio bytes, OAuth credentials and absolute local paths out of these files. Use Dropbox's create-with-conflict semantics, never overwrite another revision or enable autorename. On an ambiguous/retried upload, verify the existing file's contents against the pending revision before acknowledging success.

Use paginated folder listing and continuation cursors to discover changes. Persist incoming data before advancing its durable cursor. Missing parents, malformed files and unsupported versions are retained as pending/error states, not partially applied playlists. Persist outgoing records in the same transaction as the corresponding user edit. Keep revision history and deletion tombstones for this first release; compaction is a later protocol change. Do not interpret manual removal of a metadata file as playlist deletion.

Track references should use Dropbox file identity scoped to the paired account/library. At setup, map local Mac paths under a chosen local music root to the corresponding Dropbox music-root paths, verify file metadata/content where needed, and store the mapping. Paths aid initial matching; the persisted Dropbox ID is the stable reference. Crate iPhone already constructs track IDs from provider and remote file ID. Canonical duplicate/format aliases still need an explicit mapping; unavailable or ambiguous matches remain unresolved rather than selecting a similarly named recording.

## Conflict and deletion requirements

Sequential edits apply without interaction using revision ancestry, not device wall-clock timestamps. Edits to different playlists proceed independently. For the first release, divergent revisions of the same playlist are retained and surfaced in a native resolution dialog rather than using a last-writer-wins overwrite. Choosing a version creates a resolution revision naming every conflicting head as a parent; keeping both creates an explicitly named conflict copy with a new identity and records resolution of the original. Retain both source revisions for recovery. Automatic merging of same-playlist changes can follow later.

Represent deletions explicitly with retained tombstones so an offline device cannot silently resurrect a deleted playlist. A deletion concurrent with an edit is a conflict, not an automatic deletion or restoration. An absent file, partial listing, failed authorization or unavailable music source is not a deletion. Retain pending local changes through retries and crashes.

## Delivery sequence and acceptance

1. **Shared identity and revision contract:** fixtures cover Mac integer track IDs versus iPhone provider IDs, duplicate names/files, different local roots, missing tracks, schema versions and replay.
2. **Mac → iPhone vertical slice:** one real Mac playlist appears as a crate with the same name, membership and order; matched tracks play on iPhone; resync does not duplicate it. This is a development checkpoint, not completion of two-way sync.
3. **iPhone → Mac edits:** rename, add/remove, reorder and creation round-trip. An edit received from sync does not overwrite a newer in-progress local editor draft; refresh or conflict handling is explicit.
4. **Offline and failure acceptance:** divergent edits, delete-versus-edit, failed writes, app termination, repeated delivery, incomplete provider listings, device clock skew, unresolved members and reconnect preserve data. Back up both real libraries before migration/install acceptance.

Complete the milestone only when both directions and recovery work on the installed Mac/iPhone apps. Protocol tests, builds and installs are separate evidence from physical playback and end-to-end sync acceptance. Effort estimate follows verification of the actual Dropbox registration, root mapping and implementation plan; the earlier 2–3 day export estimate does not apply.

## Working name and installed identity

Use “Crate Mac” in this project now. If/when applying the visible application rename, preserve the current Dev bundle identifier `org.Petrichor.zak.debug`, container and library. Update build script, Xcode product name and test-host paths consistently. Renaming display text must not create a fresh empty app identity or affect the Stable installation.

## Source evidence

- Mac `Models/Core/Playlist.swift:126`: playlist UUID and mutable name; `Models/Core/PlaylistTrack.swift:4`: membership uses Mac integer track ID and position.
- Mac `Managers/Database/DMPlaylists.swift:12`: local transactional playlist save rewrites membership; unresolved remote members therefore need distinct retained sync state.
- Mac `Scripts/build-local.sh:27`, `Petrichor.xcodeproj/project.pbxproj:389`: Dev name and persistent bundle identity.
- Crate at locally recorded `aa61de5`, `src/sync/engine.ts:39`: provider-scoped track IDs; `src/storage/types.ts:26`: provider identity, root-relative path and provider hash.
- Crate at `aa61de5`, `src/library/schema.ts:65`: crate membership and order; `src/library/crate-edit.ts:70`: local editor conflict checks and transactional save.
- Crate at `aa61de5`, `src/storage/dropbox.ts:238`: PKCE/refresh-token authentication; `:479`: remote file IDs and hashes; `:491`: absent root identity evidence. Its implemented interface lists/downloads audio but does not yet publish playlist revisions.
- Crate at `aa61de5`, `src/library/oauth-credentials.ts`: SecureStore-backed device credentials.

Dropbox primary documentation checked on 2026-10-10:

- [Upload API](https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/files/upload): content-write scope and file/revision metadata.
- [OAuth guide](https://docs.dropboxapi.com/dropbox-api/docs/oauth): native authorization and refresh-token design.
- [File access guide](https://docs.dropboxapi.com/dropbox-api/docs/file-access): file identities, listings and access model.

This document supersedes the earlier iPhone-first, read-only-on-Mac transfer suggestion. The original broader feature inventory remains in [Crate Mac feature scope](crate-feature-scope.md).
