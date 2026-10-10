# Dropbox playlist protocol v1 (locked implementation contract)

The two implementations must interoperate byte-for-byte at the stored-body boundary and semantically at the decoded boundary. Do not invent platform-specific wire fields. This is a personal same-account paired-library protocol, not public sharing.

## Pairing descriptor

Path relative to the explicitly verified Dropbox music folder: `.crate-sync/v1/library.json`.

```json
{"protocolVersion":1,"libraryId":"11111111-1111-4111-8111-111111111111","accountId":"dbid:account","namespaceId":"1234","musicFolderId":"id:music"}
```

Create descriptor once with Dropbox add/no-autorename/strict-conflict; an existing descriptor must be read and verified, never overwritten. Both apps must confirm account, namespace and music-folder identity against Dropbox, not supplied file contents alone. Root selection cannot fall back on HTTP errors. Existing folder IDs are opaque, not paths. Persist pairing context and library ID. New device joins existing descriptor; simultaneous creation loser joins validated winner. Pairing changes preserve outgoing work and require explicit disconnect/new pairing; no automatic rebind.

Descriptor requires protocolVersion exactly 1, canonical lowercase library UUID, and string accountId/namespaceId/musicFolderId each 1–255 Unicode scalars without C0/C1 controls. musicFolderId must start with `id:` and contain at least one scalar after the prefix. Same 2 MiB body limit as revisions. Do not infer validity from Codable's successful structural decode alone.

## Revision

Path: `.crate-sync/v1/playlists/<playlistId>/<revisionId>.json`.

```json
{"protocolVersion":1,"libraryId":"11111111-1111-4111-8111-111111111111","playlistId":"22222222-2222-4222-8222-222222222222","revisionId":"33333333-3333-4333-8333-333333333333","parentRevisionIds":[],"deviceId":"44444444-4444-4444-8444-444444444444","name":"Warmup","deleted":false,"tracks":[{"provider":"dropbox","fileId":"id:track-a"}]}
```

All fields are required. UUID values are lowercase canonical 36-character UUID strings (accept all hex UUID versions; require hyphen positions and hex, not arbitrary path characters). Producer normalizes native UUIDs to lowercase. `parentRevisionIds` is sorted ascending, unique, maximum 32, no self-parent. Names contain 1–255 Unicode scalar values after trimming; reject empty/whitespace-only/control-character names. `tracks` is ordered, max 10000, each exactly a Dropbox provider reference with nonempty `id:`-prefixed opaque fileId max 255 Unicode scalar values, no control characters. Unique file IDs within a playlist. Tombstone: `deleted:true` requires empty tracks. UTF-8 body limit 2 MiB. Reject unsupported version, invalid structure/types, IDs that disagree with requested path/library, duplicate refs and self-parent. Unknown extra fields may be ignored only for protocolVersion 1; never reinterpret unsupported versions. No timestamps, credentials, local paths or audio bytes.

Persist exact outgoing UTF-8 bytes atomically before HTTP upload. Serializers need not order JSON keys identically across platforms. Retries reuse persisted bytes, not reserialization. Same revision ID with different bytes is a hard integrity error; on a create conflict download and byte-compare existing body, acknowledging only equality.

Cross-language scalar rules: controls mean exactly U+0000–001F and U+007F–009F; reject unpaired surrogate escapes/invalid UTF-8. Unicode format scalars (including internal ZWJ emoji sequences) are permitted. For name trimming, the forbidden leading/trailing whitespace set is exactly U+0009–000D, U+0020, U+00A0, U+1680, U+2000–200A, U+2028–2029, U+202F, U+205F, U+3000, U+FEFF. Producers trim this set before creating a revision; decoders reject untrimmed names. Do not use platform-default CharacterSet categories to broaden these rules.

## Ancestry and projection

Keep revisions/tombstones indefinitely in v1. Validate edges remain within one library and playlist; detect cycles; absent parents stay pending. Calculate heads including unpublished local revisions. One complete head can project; incomparable complete heads produce conflict, retaining current presentation. A known incomplete branch blocks claiming that playlist fully synchronized; store it for retry. Receiving child before parent must eventually yield the child without treating it as a fresh initial playlist. Never use wall clock for conflict selection.

Graph API semantics: reject a graph containing mixed library or playlist identities even when there are no cross-identity parent edges. Deduplicate equal revision IDs/content; unequal content for the same ID is an integrity error. On any incomplete ancestry return `incomplete=true` with zero actionable heads. Replayed identical input is idempotent. These graph checks supplement, not replace, raw-body collision checks in persistence.

Native resolved rows are a projection, not the wire membership. Store full ordered wire refs plus mapping snapshot/generation. For editing, references mapped to the same visible native row form one stable group, retaining their original internal order; unresolved references each remain separate groups. Explicitly removing a visible row removes every reference mapped to that row in the editor's captured mapping snapshot. Reorder replaces resolved group slots with the requested visible-group order, retaining unresolved groups in place and appending new groups. Flatten groups afterward without losing alias refs. Source-driven local deletion or remapping changes projection only, never membership. If the mapping snapshot changes while an editor is open, its save is stale.

## Atomic intents / local capture

An accepted local edit transaction captures full immutable intent: name, deleted flag, complete ordered remote/native-unmapped members, parent baseline and monotonically increasing generation. It may coalesce pending changes only while retaining pinned ancestry and enough immutable mapping data to reconstruct the full result. A dirty boolean or a later best-effort observer is not an outbox.

Mapping can occur asynchronously outside DB locks. Materialization transaction rechecks intent generation, writes exact revision bytes/revision/head/outbox, then clears only that generation. Capture next edit against latest local head including unsent revisions. Before applying any incoming projection, materialize its pending intent; if mapping blocked, retain incoming revisions but do not replace that native playlist. Suppress local capture transactionally while applying/projecting received state. Every user membership edit path participates; source-scanner effects do not produce user removals. Editor save compares expected sync generation inside its save transaction, including changes only to unresolved refs.

## Conflicts

First version does not auto-merge divergent same-playlist edits. Expose versions in existing-style native dialog. Choose a version by publishing resolution ancestry covering all current heads and its chosen content. With <=32 heads create one revision; with more, sort head IDs, create a revision parenting the first 32, then chain revisions parenting the preceding resolution plus the next <=31 heads until exhausted. Every chain member carries the chosen content. Persist/outbox the entire chain atomically, parent-first for upload. Its final revision transitively covers every captured head. Keep both additionally copies the other chosen content to a new playlist identity. Recheck current heads atomically when resolving; new heads invalidate stale resolution. Delete-versus-edit uses the same conflict flow. All source revisions remain recoverable. No unshare/detach action in v1; explicit shared deletion remains distinct from disconnecting transport, which retains all pending state.

## Discovery and transport

Use independent device PKCE/refresh credentials, content-write scope and pinned account/root context. List metadata subtree with pagination/cursor; durably store each fetched revision or pending-download obligation before advancing its cursor. Cursor reset means rescan, never delete native state. An absent Dropbox file is not a playlist tombstone. No last-writer-wins overwrite or autorename. Retry bounded failures/backoff and show actionable status; auth/root failures preserve outgoing data.

No revision publishes a shortened playlist to work around unmapped originating tracks. Known remote refs missing locally still publish and remain visible through missing-count status. Publication and projection of unrelated playlists continue when one is mapping-blocked or conflicted.
