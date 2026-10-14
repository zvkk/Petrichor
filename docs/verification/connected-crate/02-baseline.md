# Plan2 source baseline — 14 October 2026

User explicitly requested moving to Plan2 after Plan1. Scope: naming/refinement, isolated Preview, text/Rekordbox exports. No Mac Digging, audio uploads, shared metadata/smart crates or handoff implementation. Phone source and installed applications are untouched.

Base source67595ea, reviewed Plan1 Mac implementation. Its production files are identical to verified build475e8a7 (39passing tests,1pre-existing skip); subsequent changes were documentation only. Plan1 live two-device acceptance remains open and is not inferred here. The installed Mac still represents the accepted skin e989f59; Plan1 source refinements are not yet installed. New work uses feat/connected-crate-plan-2 stacked on Plan1, preserving original Mac dirty later-spec/planning edits.

Three worker lanes: Task1copy-only labels; Tasks2–3entry-purpose/Preview lifecycle; Tasks4–5immutable snapshots/formatters/native exports. Naming merges before workers finish their UI surfaces. Playback and export owners are disjoint. Current single PlaybackEngine retains its existing PlaybackBackend port; a narrow test injection initializer may expose that existing seam without replacing the production backend.

Before/after native screen, keyboard, VoiceOver, reduced-motion, minimum-window and audible checks remain acceptance work, not source-test claims. Native save-panel cancellation and actual Rekordbox import/playback need observed results. No owner acceptance is claimed by this baseline receipt. Tests/builds use isolated identities and fixture data; installed/main/Stable application identities and data are preserved.
