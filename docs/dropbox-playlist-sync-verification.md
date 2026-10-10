# Crate Mac and iPhone Dropbox playlist sync

Date: 2026-10-10. Mac product commit `07d044d`; iPhone product commits `2c084e3` and `e8ba047`. Working branches: Mac `feat/crate-dropbox-sync`, iPhone `feat/dropbox-playlist-sync`.

## Implemented behavior

Selected manual playlists/crates share their name, ordered Dropbox track references and explicit deletions in both directions. Native edits and immutable snapshot intents commit atomically. Outgoing revisions retain exact bytes for retries; durable incoming obligations precede cursor advancement. Missing tracks retain their remote positions, and conflicting edits require an explicit version choice or Keep Both.

Mac retains Petrichor's player, navigation and layout. Dropbox controls use the existing settings and playlist menus. The Dev display name is Crate Mac; its existing bundle identity remains `org.Petrichor.zak.debug`. Stable is unchanged. No audio upload/deletion, smart-rule sync, automatic unsharing or background delivery guarantee is included.

## Verified source evidence

- iPhone: Node 24 typecheck passed; lint has zero errors and 27 existing warnings. Full `npm test`: 130 suites / 2,030 tests passed; one suite/test skipped. Product commits `2c084e3` and `e8ba047`.
- Cross-platform: `python3 docs/verification/verify-dropbox-protocol.py --ios-root /Users/zakcupido/Desktop/Atlas/Worktrees/crate-dropbox-playlists` compiles the production Swift decoder/graph and executes the production TypeScript decoder/graph. Both agree on 27 revision, six descriptor and 12 ancestry cases; known fields round-trip in both directions without changes.
- Shared fixture copies have SHA256 `85757b94522a8565c9f67b8ee02adb2f8c5f9f14f8f29b2c4575539a15ca8960`.
- iPhone production Expo export and signed Release build passed. Code signature, main bundle identity, embedded app configuration and provider configuration verified; demo data disabled. Native code is unchanged; source tests and the build are not phone acceptance.
- Mac final green11: 31 XCTest cases executed, one existing skip, zero failures. Includes same-ID path relocation during async verification and malformed-graph isolation. Log: `/private/tmp/crate-sync-mac-green11.log`.

Phone tests include real SQLite reopen/rollback, unresolved references, aliases after canonical promotion, explicit removals, stale editor generation, concurrent local/remote edits, 65-head resolution chains, replay/integrity errors, durable discovery, same-run edits, pinned-root rejection and discovery racing normal ingestion. Mac tests cover the corresponding native store/transport behaviors, including exact Dropbox content hashes and auth cancellation/retry.

## Independent review

GPT-6.1 Sol implemented each platform. GPT-6 Astra performed architecture, protocol and platform reviews; the primary verified findings directly and ran host builds and the cross-platform harness.

Reviewed fixes include Unicode/graph agreement, ordinary edits retaining their own ancestry, alias removals after canonical promotion, queued sync reruns, outgoing root verification, insert-only track hydration, Dropbox create-folder WritePath requirements, added-track ordering, invalidation of stale native mappings, and preservation of an existing library identity after descriptor loss. Astra approved both targeted final source reviews, conditional on passing checks. Review does not establish live-account or physical-device acceptance.

## Setup and remaining acceptance

1. The Dropbox registration must permit `account_info.read`, `files.metadata.read`, `files.content.read`, and `files.content.write`, with native redirect URI `petrichor-zak-dev://dropbox-callback` alongside the existing phone redirect. Renew each app's consent if the write grant is absent. Public application configuration is supplied through ignored local build settings; tokens stay in device Keychain/SecureStore.
2. Pair the same real Dropbox account and existing music folder on both devices. On Mac, select the matching local music root. Mapping verifies relative location and Dropbox content hash; local-only/unmatched originating tracks block that playlist rather than publish a shortened version.
3. Before updating either installed app, back up and verify its complete existing data. Keep the current bundle IDs and never uninstall to deliver this candidate.
4. Run a real manual playlist Mac → iPhone, edit it on iPhone → Mac, test offline/retry/conflicting edits, and confirm matched audio plays. These live checks remain pending.

Read-only readiness checks found a paired iPhone 15 Pro and a Mac Dev library with 2,102 tracks but no user-created manual playlist. The local Dropbox app folder had 162 audio paths, 160 matching relative paths in the Mac music index. This establishes neither remote file identity nor content equality.

The browser integration reported no available browser, so the Dropbox developer registration could not be inspected or changed. Its callback/grant configuration still requires verification.

No real Dropbox metadata was written, no app was installed, and no live two-way sync or physical playback acceptance is claimed by this report. No shared branch was pushed or merged.

## Build artifacts

Primary checkpoint: `/Users/zakcupido/Documents/Codex/checkpoints/2026-10-10-crate-dropbox-sync`.

iPhone candidate: `MusicApp.app` in the checkpoint, built from product commit `e8ba047`. Receipt: `ios-build-receipt.json`; source branch also contains documentation commit `0bd3f29`. Hermes SHA256: `8a86b48f68aa59071e69a08a536d2d14cefb182bd49c696108666f6420de2958`.

Mac candidate: `Crate Mac.app` in the checkpoint, built from `07d044d`. Native Debug build and ad-hoc signature verification passed. Display name is Crate Mac; preserved bundle ID `org.Petrichor.zak.debug` and URL scheme `petrichor-zak-dev` verified. Public Dropbox configuration is present without recording its value. Receipt: `mac-build-receipt.json`. Build and test artifacts are separate from installed application acceptance.
