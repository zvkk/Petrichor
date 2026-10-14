# 06 — Continue listening between Mac and iPhone

Status: draft for review. Governing requirements: [Connected Crate](README.md). Requires connection and explicit handoff support on both clients. Dropbox foreground delivery is the existing transport; this is not an always-online remote-control service.

## User flow and presentation

Add **Continue on iPhone…** / **Continue on Mac…** to the existing player overflow/Playback menu. The command chooses a previously paired capable device. Do not add a permanent device sidebar, replace AirPlay/audio-output controls, or move the current player. Radio streams and Preview auditions are ineligible.

On the target, offer **Continue [track] from [device]** through its existing in-app notification/player action pattern, with **Continue here** and **Dismiss**. Merely opening an app, receiving a file or changing a shared crate never starts audio. If target playback is active, confirm **Replace current playback?** before admitting the request. Dismiss/Cancel before acceptance leaves both sessions unchanged. Cancellation after acceptance prevents target playback but can race with an already valid source pause; explain that state and retain the source snapshot for explicit Resume.

Display truthful states: **Waiting for your other device**, **Preparing audio…**, **Ready to continue**, **Playback changed—send again**, **Some queue tracks are unavailable**, and **Request expired**. Both apps must be available to complete the handshake. Suspended/offline/signed-out clients do not promise instant handoff; ordinary playback stays usable while waiting.

## Portable session snapshot

Each immutable offer is bound to the verified library, sender/target persistent device IDs, unique request ID and sender session/operation generation. Include ordered queue **occurrences** with independent occurrence IDs and verified Dropbox file references/content versions, current occurrence index, normal origin if portable, elapsed position, effective ordered queue, underlying unshuffled order, shuffle state and repeat mode. Maximum 10,000 occurrences and 2 MiB encoded body; validate index, identity, finite nonnegative position and all mode values.

Stable occurrence identity is required for repeated tracks; file ID alone cannot identify the playing occurrence. Origins use explicit shared crate IDs where mapped. Otherwise retain a display-only origin label and no actionable foreign native ID. Never infer an origin from track membership or use Mac runtime UUIDs as phone IDs. Device volume, output route, EQ, ReplayGain, crossfade preference, account tokens, local paths and preview settings are not transferred.

All queue members must have verified shared identities. An unmapped local-only member blocks full-queue transfer and identifies affected tracks. A user may explicitly choose **Continue this track only** if the current recording is mapped; label that choice before replacing target playback. Do not silently shorten or deduplicate a queue, reorder it by current crate contents, re-shuffle an already ordered queue, or guess an unavailable recording by name.

## Ownership-safe handshake

Use separate immutable offer/accept/ready/consumed/cancel records under `.crate-sync/v2/handoff/<requestId>/`, with strict per-record type/version, request/library/device/path validation. Durable writes/replays are idempotent. Only the nominated target can accept the offered snapshot and only its sender can authorize source pause. A second request supersedes the sender's pending one through cancellation, not mutable-file overwrites.

1. Sender captures the current normal session under its operation generation and persists/publishes an offer. Playback continues while the target is absent. New Play/Preview/source replacement, queue edits, seek/mode changes or cancellation invalidate that pending offer and publish cancellation when possible.
2. Target receives it, waits for explicit Continue here/replace confirmation, then verifies/resolves exact audio and occurrence order through its ordinary media-claims/download path. Before requesting acceptance it must be ready to load/seek that recording, or show a download/failure state. User cancellation invalidates its target operation generation.
3. Target publishes an accept naming the exact offer body identity. Sender rechecks the captured source generation/queue/intent. If changed or expired, it rejects/cancels without pausing the new playback. Otherwise it samples final position, pauses that same entry once, and publishes ready with final position plus the accepted immutable session identity. Failure retains a retryable pending result; the UI explains source pause while ready delivery waits.
4. Target verifies ready, its own still-current accepted operation and exact media identity, then atomically records a one-shot consumed admission before issuing load/seek through the current request-admission path. Autoplay is allowed only because this same target operation received explicit Continue here. Record started or failed outcome afterward; a crash between admission and the engine command requires a new explicit retry, not automatic replay. Replayed ready/consumed cannot restart playback or overwrite a newer target session.
5. Sender completion does not erase its local queue or session record. No automatic remote command resumes it after cancellation/failure; the user can Resume normally. Target failure after source pause shows Retry and **Resume on source** guidance, preserving both recoverable snapshots.

Expiry uses local monotonic ownership checks, not device-wall-clock ordering: sender offers are actionable for ten minutes in the same app process, and a receiver must consume ready within sixty seconds of first receipt in the same accepted operation. Restart invalidates outstanding process-owned handoff operations and requires a new explicit request; persisted records are retained for explanation/replay rejection. Both peers reject offers/accepts from cancelled/superseded requests. Display timestamps may aid recognition but confer no command authority.

During final loading/seeking, guard source/occurrence and operation identity after every await. Clamp against actual decoded duration; unknown duration starts at zero with an explanation, and a position beyond the decoded end clamps to a valid position without pretending decode/seek succeeded. Repeat/shuffle restoration cannot start an unintended occurrence.

## Recording and persistence

Handoff completion is not a completed listening event. Do not increment play count or emit a scrobble merely for offering, pausing, receiving or seeking. Normal target playback follows its existing qualified listening behavior; stopped source segments do not synthesize EOF. Preview remains excluded. Cross-device deduplication of later listening history/scrobbles is not promised because this milestone does not synchronize listening-event records.

Ordinary restart restoration retains its existing local ownership and user intent. Handoff records do not become a foreign auto-resume instruction. Transport discovery runs off the UI thread, and no network lock spans an audio-engine command.

## Owners and acceptance

Mac: `Application/PlaybackSessionStore.swift`, `Application/AppCoordinator.swift`, `Managers/PlaybackManager.swift`, `Managers/PlaybackQueueMirror.swift`, existing player menus. iPhone: `src/player/index.ts:43–79`, `src/playback/requests.ts:165`, `:298` and `:411`, player action/presentation owners. Reuse the current engine, authoritative position samples, media claims and generation-based admission; do not add a second player.

Acceptance covers a real Mac → phone → Mac transfer; source pauses once after valid acceptance; target resumes the exact recording/position/order/modes only after explicit consent; repeated occurrences; target already playing; source changes/seek/queue mutation during every await; slow downloads and unsupported/corrupt audio; cancellation and target/source restart; monotonic expiry; duplicate/reordered/replayed records; clock skew; disconnected/wrong-root clients; preserved local sessions and no fabricated play/scrobble credit. Audible timing checks and physical-device controls are required in addition to source state-machine tests.
