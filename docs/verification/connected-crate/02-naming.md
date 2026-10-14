# Plan 2 naming source receipt — 14 October 2026

Source baseline: `67595ea54f09d1fcff9c6e75d85be10d030929e7`, isolated branch `task/crate-plan2-naming`. This receipt covers Task 1 copy implementation only. Naming native/owner acceptance remains pending.

## Inventory and scope

Inspected `rg -n 'Playlist|playlist|Playlists|playlists' Views Models/Enums PetrichorApp.swift`, the authored `Resources/Localizable.xcstrings` entries and the display helpers used by crate detail. The source inventory includes:

| Surface | Copy changed |
| --- | --- |
| Toolbar and app menus | Crates, New crate action labels, Crate from selection, Import crates, Export crates |
| Sidebar and pinned-item menus | Crates, New crate, Smart crate, Edit crate, Delete crate and options/help |
| Track context menus/editor row helpers | Add to crate, Remove from crate, In crate |
| Crate editor/detail/selection | New crate, Edit crate, Edit smart crate, name/artwork fields, type labels, empty/missing/error states and reorder help |
| Import/export sheet and notifications | Crates; explicit M3U playlist files for the external format |
| Library settings and display helpers | Highest-quality help, clear-library explanations, entity display type, empty-state descriptions |
| Sync errors | Five display-only error-description phrases now say crate; no codec or protocol changes |

`Models/Core/Entity.swift`, `Utilities/Constants.swift` and `Models/PlaylistSync/PlaylistSyncProtocol.swift` are display-string owners reached from the listed UI. Their inclusion changes only copy. Native collection menu labels distinguish `.stations`, retaining radio Edit/Delete and Collections wording.

Preserved internal `Playlist`, `Sections.playlists`, symbol/case/property names, database/notification/UserDefaults keys, protocol paths and IDs. Built-in collection names and authored names remain untouched, including sample authored names in previews. Radio Collections remain unchanged. SwiftUI preview titles and diagnostic/internal identifiers retain Playlist. App Intent definitions outside this UI pass retain their existing action naming; any separate Shortcuts terminology pass is outside this task.

Localization changes rename the corresponding authored source keys and English plural forms. Existing foreign-language translations are retained verbatim, without automatic translation. Three old case/phrase variants converge onto shared keys (two Add-to variants and Create/New crate); duplicate entries are consolidated. Foreign-language product terminology needs a human localization pass if equivalent Crate branding is desired there.

## Verification observed

- `git diff --check`: passed.
- `xcrun swiftc -frontend -parse` over all 19 changed Swift files: passed. This checks syntax, not a native build or type checking.
- JSON parsing with duplicate-key rejection: passed; catalog has 825 unique keys versus 828 at baseline.
- Inspected changed catalog English plural variants and verified carried foreign-language translations match a baseline entry exactly.
- Reviewed diffs for string-only changes, plus the two music/radio menu-label conditions and the pinned-radio delete-title condition. Menu action closures/order, keyboard shortcuts, selection handlers and layout modifiers remain unchanged in source.

No mirror-image unit tests were added for this copy-only task. The integrating primary agent owns the native build after concurrent workers finish.

## Comparison and acceptance limits

No baseline native screenshots or after-change captures were obtained. Native app automation is unavailable through the current CUA surface. No claim of rendered equivalence follows from source inspection or syntax parsing.

Pending direct comparison: Home; Library table/grid; album; crate detail/editor; queue; Settings at 1200×800 and 1100×600 with identical data, split widths, selected rows and scroll state. Check Light/Dark/Auto, inactive-window selection contrast, menu order and long text. Pending interaction acceptance: VoiceOver, focus/text entry, cancellation, multiselection, drag/drop, sorting, scroll preservation, Space, keyboard and reduced motion. No installation, launch, audible playback, signature validation or owner acceptance was performed for this task.
