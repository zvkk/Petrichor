import Foundation
import AppKit

/// Owns an audition independently of the ordinary queue. All operations are on main.
@MainActor
final class PreviewSession {
    private unowned let manager: PlaybackManager
    private(set) var generation: UInt64 = 0
    private(set) var entryID: AudioEntryId?
    private var original: Snapshot?
    private var waitingForReady = false
    private var playWhenReady = true
    var isActive: Bool { original != nil }

    private struct Snapshot {
        let queue: [Track]
        let cursor: Int
        let source: PlaylistManager.QueueSource
        let playlist: Playlist?
        let shuffle: Bool
        let repeatMode: RepeatMode
        let track: Track?
        let position: Double
        let wasPlaying: Bool
    }

    init(manager: PlaybackManager) { self.manager = manager }

    func begin(track: Track) {
        guard manager.canPreview(track) else { return }
        let playlists = manager.playlistManager
        if original == nil {
            // Flush the ordinary session before any audition state becomes visible.
            if let coordinator = AppCoordinator.shared, coordinator.playbackManager === manager {
                coordinator.savePlaybackState()
            }
            original = Snapshot(queue: playlists.currentQueue, cursor: playlists.currentQueueIndex,
                                source: playlists.currentQueueSource, playlist: playlists.currentPlaylist,
                                shuffle: playlists.isShuffleEnabled, repeatMode: playlists.repeatMode,
                                track: manager.currentTrack, position: manager.actualCurrentTime,
                                wasPlaying: manager.isPlaying)
        }
        generation &+= 1
        manager.beginSourceGeneration()
        manager.pendingRestoreResume = nil
        manager.pendingPreviewRestore = nil
        manager.pendingPlayOnRestore = false
        manager.audioPlayer.pause()
        let id = AudioEntryId.fresh()
        entryID = id
        waitingForReady = true
        playWhenReady = true
        manager.registerEntry(id, track: track, purpose: .preview)
        manager.mirror = []
        manager.unmirroredTracks = [id.id: track]
        manager.injectedNext = nil
        manager.currentEntryId = id
        manager.currentTrack = track
        manager.currentFullTrack = nil
        manager.restoredUITrack = nil
        manager.currentTime = 0
        manager.restoredPosition = 0
        manager.isPlaying = true
        manager.isPreviewing = true
        manager.audioPlayer.stop()
        manager.audioPlayer.setQueue([QueueEntry(entryId: id, url: track.url)], startingAt: 0, startPaused: true)
        manager.publishNowPlayingMetadata(for: track)
        manager.loadFullTrack(for: track)
    }

    /// Called only after the actual entry's paused-load notification.
    func ready(entryID id: AudioEntryId) {
        guard waitingForReady, matches(id, generation: generation) else { return }
        waitingForReady = false
        let token = generation
        let defaults = UserDefaults.standard
        let value: (String, Double) -> Double = { key, fallback in
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        let start = (try? PreviewPolicy.startSeconds(duration: manager.audioPlayer.duration,
            fraction: value("previewFraction", 0.2), minSeconds: value("previewMinSeconds", 20),
            maxSeconds: value("previewMaxSeconds", 75))) ?? 0
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
        let refreshed: (Track) -> Track = { original in
            latest.first { candidate in
                if let id = original.trackId { return candidate.trackId == id }
                return candidate.url == original.url
            } ?? original
        }
        let restoredQueue = saved.queue.map(refreshed)
        let restoredTrack = saved.track.map(refreshed)
        cancelForOrdinaryPlayback()
        playlists.installRestoredQueue(restoredQueue, cursor: saved.cursor, source: saved.source, playlist: saved.playlist)
        playlists.isShuffleEnabled = saved.shuffle
        playlists.repeatMode = saved.repeatMode
        manager.audioPlayer.stop()
        manager.currentEntryId = nil
        manager.currentTrack = restoredTrack
        manager.currentFullTrack = nil
        manager.currentTime = saved.position
        manager.restoredPosition = saved.position
        manager.isPlaying = false
        guard let track = restoredTrack else { return }
        guard manager.canPreview(track) else {
            manager.mirror = []
            NotificationManager.shared.addMessage(.error, String(localized: "Cannot play '\(track.title)': File not found"))
            return
        }
        manager.rebuildQueueMirror(for: restoredQueue)
        let entries: [QueueEntry]
        let index: Int
        let id: AudioEntryId
        if manager.mirror.indices.contains(saved.cursor), restoredQueue[saved.cursor].url == track.url {
            entries = manager.mirrorEntries(); index = saved.cursor; id = entries[index].entryId
        } else {
            manager.mirror = []
            id = .fresh(); index = 0
            manager.registerEntry(id, track: track, purpose: .ordinary)
            entries = [QueueEntry(entryId: id, url: track.url)]
        }
        manager.currentEntryId = id
        manager.pendingPreviewRestore = (id, saved.position, manager.sourceGeneration)
        manager.audioPlayer.setQueue(entries, startingAt: index, startPaused: true)
        manager.loadFullTrack(for: track)
        manager.publishNowPlayingMetadata(for: track)
    }

    func cancelForOrdinaryPlayback() {
        generation &+= 1
        original = nil
        entryID = nil
        waitingForReady = false
        manager.isPreviewing = false
        manager.pendingPreviewRestore = nil
        manager.beginSourceGeneration()
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
