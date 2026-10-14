import Foundation
import AppKit

/// Owns an audition independently of the ordinary queue. All operations are on main.
@MainActor
final class PreviewSession {
    private unowned let manager: PlaybackManager
    private(set) var generation: UInt64 = 0
    private(set) var entryID: AudioEntryId?
    private var original: OrdinaryPlaybackSnapshot?
    private var waitingForReady = false
    private var playWhenReady = true
    var isActive: Bool { original != nil }

    init(manager: PlaybackManager) { self.manager = manager }

    func begin(track: Track) {
        guard manager.canPreview(track) else { return }
        if original == nil { original = manager.captureOrdinaryPlaybackForPreview() }
        generation &+= 1
        let id = AudioEntryId.fresh()
        entryID = id
        waitingForReady = true
        playWhenReady = true
        manager.installPreviewPlayback(track: track, entryID: id)
    }

    /// Called only after the actual entry's paused-load notification.
    func ready(entryID id: AudioEntryId) {
        guard waitingForReady, matches(id, generation: generation) else { return }
        waitingForReady = false
        let token = generation
        let start = PreviewSettings.load().startSeconds(duration: manager.audioPlayer.duration)
        guard matches(id, generation: token) else { return }
        // seek is synchronous in the existing backend port. Check again after it:
        // test backends can reenter here and production may publish delegate work.
        guard manager.audioPlayer.seek(to: start), matches(id, generation: token) else { return }
        manager.currentTime = start
        if playWhenReady { manager.audioPlayer.resume() }
    }

    func togglePlayPause() {
        if waitingForReady {
            playWhenReady.toggle()
            manager.isPlaying = playWhenReady
            return
        }
        guard let id = entryID, matches(id, generation: generation) else { return }
        manager.audioPlayer.togglePlayPause()
    }

    private func matches(_ id: AudioEntryId, generation token: UInt64) -> Bool {
        isActive && token == generation && entryID == id && manager.currentEntryId == id
            && manager.audioPlayer.currentEntryId == id
    }

    func end() {
        guard let saved = original else { return }
        let playlists = manager.playlistManager
        // Membership and order are frozen; deliberate metadata edits remain current.
        let latest = [manager.currentTrack].compactMap { $0 } + playlists.currentQueue
        let byID = Dictionary(latest.compactMap { track in track.trackId.map { ($0, track) } },
                              uniquingKeysWith: { first, _ in first })
        let byURL = Dictionary(latest.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let refreshed: (Track) -> Track = { original in
            if let id = original.trackId { return byID[id] ?? original }
            return byURL[original.url] ?? original
        }
        let restoredQueue = saved.queue.map(refreshed)
        let restoredTrack = saved.track.map(refreshed)
        cancelForOrdinaryPlayback()
        manager.restoreOrdinaryPlaybackAfterPreview(saved, queue: restoredQueue, track: restoredTrack)
    }

    func cancelForOrdinaryPlayback() {
        generation &+= 1
        original = nil
        entryID = nil
        waitingForReady = false
        manager.invalidatePreviewPlayback()
    }
}

extension PlaybackManager {
    func canPreview(_ track: Track) -> Bool {
        guard currentStation == nil, track.url.isFileURL,
              FileManager.default.isReadableFile(atPath: track.url.path),
              let values = try? track.url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return true
    }

    func cancelPreviewForOrdinaryPlayback() {
        MainActor.assumeIsolated { previewSession.cancelForOrdinaryPlayback() }
    }

    func endPreviewBeforeQueueEdit() {
        MainActor.assumeIsolated { previewSession.end() }
    }
}

/// Shared by native context and keyboard menus; re-evaluated when invoked.
enum PreviewCommandPolicy {
    static var hasEditableFocus: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }
}
