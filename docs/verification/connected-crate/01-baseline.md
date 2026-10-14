# Plan 1 execution baseline — 14 October 2026

Scope authorized: implement connected collection and ordinary crate sync only; stop before milestone 2. Implementation request also invokes implement-spec and subagent-driven execution. No installation is authorized merely by this receipt.

| Source | Exact clean implementation base |
|---|---|
| Mac | 9523a457a83bfc33cfd7753015d7ed6c5cedbc37; accepted skin e989f59246b0e0668b73ac3530e974be5ca60b3c |
| Latest accepted phone source | 93bb94a; fix/native-glass-transition; clean at start |
| Read-only sync donor | 4c6567f55cc723727835a69a1fbcbb5ec5ceac12 |

Original Mac worktree has uncommitted later-milestone spec04/05 and six planning documents. They remain untouched; only the selected Plan1 is copied here. Phone native-glass and Digging work through93bb94a is preserved; old sync UI is never substituted.

Target phone contains 12 historical migrations, with Digging at11 and historical repair at12. The sync feature appends migration13; donor migration11 is not reused as history.

Mac/donor protocol fixture SHA256: `ab0ec0b287522590515461993e173de8792e44e2ca018b2d0846b2295e6991e5`. Latest phone initially has no fixture or sync modules; Task3 copies exact bytes.

## Writer ownership inventory

Explicit user commands: crates.ts ordinary create/rename/delete/add/remove/reorder and queue bulk/create; crate-edit.ts transactional editor; triage-decisions.ts deliberate assignments/Undo; browse-digging.ts membership Add and token-checked Undo; rule-digging-commands.ts Add/Undo. Every successful shared membership change captures intent in its owning transaction; events follow commit.

Projection/source maintenance: track-lifecycle.ts canonical/alias reference transfer; reconcile.ts and duplicate-reconciliation.ts representative selection/transfer; tracks.ts track alias promotion; purge.ts bulk source removal. These must preserve wire identity and never manufacture explicit user removals. Remote sync projection changes native membership with capture suppressed; its editor token still invalidates drafts.

Mac DMPlaylists.swift and PMRegularPlaylists.swift already capture manual playlist writes. Task6 audits their coverage and editor guard while preserving current workflows.

## Evidence boundary

Baseline source checks and visual captures are recorded separately when performed. No screenshots, live two-device behavior or audible acceptance are claimed by this source receipt. Existing accepted skin checkpoint is reference evidence, not a fresh capture of every requested state. C1–C7 live acceptance remains open until observed on the matching builds with verified data backups.

Independent unchanged-baseline checks: phone schema suite 28/28 passed and Mac PlaylistSyncTests16/16 passed. Full integrated results follow in the acceptance receipt.

Installed-phone distinction: baseline93bb94a contains the accepted footer correction, whose recorded candidate was not yet installed. The prior combined glass/Digging delivery used source6b41f18. This receipt freezes source, not an installed93bb94a binary.
