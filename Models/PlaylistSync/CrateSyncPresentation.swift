import Foundation

/// Metadata delivery and audio availability are deliberately separate concerns.
enum CrateSyncPresentation {
    static func summary(state: SyncPlaylistState?, connected: Bool, working: Bool, queued: Bool) -> String {
        guard connected else { return state == nil ? String(localized: "Connect Dropbox to share this crate") : String(localized: "Reconnect Dropbox") }
        guard let state else { return String(localized: "Share with iPhone") }
        if state.issue == "conflict" { return String(localized: "Changes on both devices") }
        if working { return String(localized: "Syncing…") }
        if state.intent != nil || queued || state.issue != nil || state.heads.isEmpty || state.appliedHead == nil {
            return String(localized: "Changes waiting to sync")
        }
        return String(localized: "Crate synced")
    }
    static func unavailable(_ state: SyncPlaylistState) -> Int {
        (state.intent?.members ?? state.members).filter { $0.fileId != nil && $0.localTrackID == nil }.count
    }
    static func needsAdding(_ state: SyncPlaylistState) -> Int {
        (state.intent?.members ?? state.members).filter { $0.fileId == nil }.count
    }
}
