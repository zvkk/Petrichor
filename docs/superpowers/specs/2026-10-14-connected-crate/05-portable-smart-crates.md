# 05 — Portable smart crates

Status: draft for review. Governing requirements: [Connected Crate](README.md). Depends on connection and the agreed shared catalogue/track-state contract in [04](04-shared-track-state.md).

## Outcome and user flow

Share a supported live smart-crate definition, edit it on either device and resolve it against the shared collection with consistent predicate/order semantics. A smart crate stays recognisably the existing native smart editor and detail view. Do not replace Mac's broader local rule system or treat an ordered song snapshot as a smart definition.

The Mac's current **Smart crate** editor keeps its rule rows, All/Any choice, sorting, limit, live count and auto-update setting. Add **Share with iPhone** beside existing crate actions only after a compatibility check. The phone keeps its current richer `SmartRuleV2` editor. Existing local-only rules remain available without changing semantics.

If a rule cannot be represented exactly, keep the original collection and explain the specific incompatible rule. Offer **Keep local** or **Share a regular snapshot…**. The latter creates a new ordinary shared crate with an explicit name and fresh resolved membership; it never converts or renames the original. A Mac smart crate with auto-update disabled is a frozen snapshot and cannot be presented as a shared live rule without an explicit user change.

Received unsupported/newer definitions are retained as unavailable with **Update Crate to use these rules**. Do not turn them into empty crates, drop predicates or enable playback/export using a partial interpretation.

## Existing model differences

Current iPhone `src/library/smart-crate-rules.ts:3–28` defines `SmartRuleV2`, All/Any, up to 20 predicates, typed text/number/date/boolean operators, sort direction and a limit. `src/library/smart-crates.ts:25` is a **legacy** interface; use its explicit decoder/conversion only for old rules. Current date queries use local calendar-day semantics and preserve legacy elapsed-day/null-order behavior.

Mac `Models/Core/Playlist.swift:14` stores string-valued rules, its own condition enum, sorting/limit and `autoUpdate`. `Models/Core/SmartPlaylistField.swift:25` exposes 15 fields, with both SQL and in-memory evaluators. BPM, label, musical key and lossless are not currently all offered as native Mac smart fields. Regex, composer/full-path and local history/date predicates are not equivalent to every phone predicate.

Implement explicit adapters and a versioned shared rule profile; do not copy either platform's raw JSON and assume the other evaluator understands it. Support new portable fields in the existing Mac rule editor where needed, retaining its current layout.

## Portable profile 1

Wire definition version is **1**, separate from phone's local `SmartRuleV2.version` and the v2 transport namespace. Store definitions under `.crate-sync/v2/smart-crates/<sharedCrateId>/<revisionId>.json`. Metadata/name/deletion and definition revisions use one immutable ancestry stream per smart crate, with the same atomic/conflict/payload protections as regular crates. Definition payload maximum 256 KiB; limit 1–10,000; 1–20 conditions; flat `all` or `any` grouping.

| Type | Shared profile |
| --- | --- |
| Text | title, artist, album, albumArtist, genre, label, musicalKey; contains/notContains, equals/notEquals, startsWith/endsWith. |
| Numeric | bpm, year, durationSeconds, trackNumber, discNumber; equals, greaterThan, atLeast, lessThan, atMost, inclusive between. |
| Boolean | favourite and lossless; explicit true/false. |
| Sort | title, artist, album, bpm, durationSeconds; asc/desc; missing values last in both directions; deterministic final tie by stable file ID. |
| Eligibility | Explicit all-shared-tracks predicate when an otherwise empty All definition is intended. |

Profile strings are NFC normalized. Text comparison uses ASCII case folding with non-ASCII scalars compared exactly; both implementations must use this explicit profile rather than locale-dependent comparisons or SQLite defaults. User-authored display case remains intact. Missing/unknown field data matches no text/numeric/boolean predicate, including negative predicates; it is not zero, empty display fallback or false. An explicit known false favourite/lossless value is distinct from missing state.

Finite numeric bounds follow the shared metadata field constraints; duration is finite/nonnegative seconds, and between requires lower ≤ upper. Field/operator values are validated before saving/decoding. Bind SQL parameters; do not concatenate user field names, operators or values into queries. A between atom remains one predicate inside Any; expanding it into two OR conditions would change meaning and is prohibited.

Source-path/filename, composer, regex, playCount, lastPlayed, neverPlayed, device dateAdded, calendar-relative filters, legacy elapsed-day filters and legacy null-order exceptions are **local-only in profile 1**. They cannot be silently rewritten into portable conditions. Current richer local editors retain them. Their exact rule sharing requires a later profile with agreed path/history/time semantics, rather than broadening this release by inference.

## Catalogue and evaluation

Candidates are verified records in the shared catalogue, not every local Mac/phone file. Evaluate against the same acknowledged base content version plus resolved field/favourite overrides. Use original shared-file lossless/duration data rather than a device's preferred encoding or downloaded state. Hydrated aliases map the resulting file references to each native projection while retaining underlying shared identities.

A peer that has not yet received the complete relevant catalogue/override/definition revisions shows **Updating matches…**, retaining its last complete result and disabling fresh export/play decisions from a partial result. A missing local download does not remove an otherwise matched shared member. Display available/unavailable counts separately; materialize the same ordered wire membership from an equivalent shared snapshot even when native visible alias grouping differs.

Use a snapshot/generation for live count, save, playback and export. A library/override update invalidates cached matches after commit; a stale generation cannot publish a count or start an older resolved queue. Native menus/transport remain unchanged. Regular-crate membership assignment rejects smart definitions; queue-to-crate creates an explicit regular collection when requested.

Conflict resolution shows both definitions and match summaries against the same complete catalogue snapshot. **Use Mac rules**, **Use iPhone rules**, or **Keep both** publishes valid ancestry without losing either source. Deleting shared smart metadata never deletes audio or local unsupported originals.

## Acceptance

Cross-platform golden fixtures must cover every profile field/operator, All/Any/between semantics, Unicode/ASCII casing, absent versus false/zero, null ordering, stable ties, all-eligible, limits and invalid/unknown versions. Run production Swift and TypeScript codecs/evaluators against the same fixtures; test Mac SQL and in-memory paths for agreement.

Validate exact supported-rule round trips and conflict resolution; unsupported regex/path/date/history and frozen smart crates retain their original definitions; snapshot sharing is explicitly regular; remote-only audio remains matched; incomplete catalogue generations cannot claim fresh results; live edits refresh an open detail; playback and export use fresh immutable snapshots. Finish with real two-device authoring, native editor checks and audible playback of matched recordings.

Profile expansion is a separately versioned change. No shared listening-history or date semantics are implied by this milestone.
