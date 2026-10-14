import Foundation

struct OrdinaryPlaybackSnapshot {
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

/// PlaybackManager owns the ordered mutations required to switch engine sessions.
@MainActor
extension PlaybackManager {
    func captureOrdinaryPlaybackForPreview() -> OrdinaryPlaybackSnapshot {
        if let coordinator = AppCoordinator.shared, coordinator.playbackManager === self {
            coordinator.savePlaybackState()
        }
        return OrdinaryPlaybackSnapshot(
            queue: playlistManager.currentQueue,
            cursor: playlistManager.currentQueueIndex,
            source: playlistManager.currentQueueSource,
            playlist: playlistManager.currentPlaylist,
            shuffle: playlistManager.isShuffleEnabled,
            repeatMode: playlistManager.repeatMode,
            track: currentTrack,
            position: actualCurrentTime,
            wasPlaying: isPlaying
        )
    }

    func installPreviewPlayback(track: Track, entryID id: AudioEntryId) {
        beginSourceGeneration()
        pendingRestoreResume = nil
        pendingPreviewRestore = nil
        pendingPlayOnRestore = false
        audioPlayer.pause()
        registerEntry(id, track: track, purpose: .preview)
        mirror = []
        unmirroredTracks = [id.id: track]
        injectedNext = nil
        currentEntryId = id
        currentTrack = track
        currentFullTrack = nil
        restoredUITrack = nil
        currentTime = 0
        restoredPosition = 0
        isPlaying = true
        isPreviewing = true
        audioPlayer.stop()
        audioPlayer.setQueue([QueueEntry(entryId: id, url: track.url)], startingAt: 0, startPaused: true)
        publishNowPlayingMetadata(for: track)
        loadFullTrack(for: track)
        retireUnownedEntries()
    }

    func restoreOrdinaryPlaybackAfterPreview(
        _ snapshot: OrdinaryPlaybackSnapshot, queue restoredQueue: [Track], track restoredTrack: Track?
    ) {
        playlistManager.installRestoredQueue(
            restoredQueue,
            cursor: snapshot.cursor,
            source: snapshot.source,
            playlist: snapshot.playlist
        )
        playlistManager.isShuffleEnabled = snapshot.shuffle
        playlistManager.repeatMode = snapshot.repeatMode
        audioPlayer.stop()
        currentEntryId = nil
        currentTrack = restoredTrack
        currentFullTrack = nil
        currentTime = snapshot.position
        restoredPosition = snapshot.position
        isPlaying = false
        mirror = []
        unmirroredTracks = [:]
        injectedNext = nil
        restoredUITrack = nil
        retireUnownedEntries()
        guard let track = restoredTrack else {
            audioPlayer.setNowPlayingMetadata(nil)
            return
        }
        publishNowPlayingMetadata(for: track)
        guard canPreview(track) else {
            mirror = []
            NotificationManager.shared.addMessage(.error, String(localized: "Cannot play '\(track.title)': File not found"))
            return
        }
        rebuildQueueMirror(for: restoredQueue)
        let entries: [QueueEntry]
        let index: Int
        let id: AudioEntryId
        if mirror.indices.contains(snapshot.cursor), restoredQueue[snapshot.cursor].url == track.url {
            entries = mirrorEntries(); index = snapshot.cursor; id = entries[index].entryId
        } else {
            mirror = []
            id = .fresh(); index = 0
            registerEntry(id, track: track, purpose: .ordinary)
            entries = [QueueEntry(entryId: id, url: track.url)]
        }
        currentEntryId = id
        pendingPreviewRestore = (id, snapshot.position, sourceGeneration)
        audioPlayer.setQueue(entries, startingAt: index, startPaused: true)
        retireUnownedEntries()
        loadFullTrack(for: track)
        publishNowPlayingMetadata(for: track)
    }

    func invalidatePreviewPlayback() {
        isPreviewing = false
        pendingPreviewRestore = nil
        pendingPlayOnRestore = false
        beginSourceGeneration()
    }

    func finishPreviewRestoration(entryID id: AudioEntryId) {
        guard let pending = pendingPreviewRestore, pending.entryId == id,
              pending.generation == sourceGeneration, currentEntryId == id,
              audioPlayer.currentEntryId == id else { return }
        pendingPreviewRestore = nil
        let sought = audioPlayer.seek(to: pending.position)
        guard pending.generation == sourceGeneration, currentEntryId == id,
              audioPlayer.currentEntryId == id else { return }
        let shouldPlay = pendingPlayOnRestore
        pendingPlayOnRestore = false
        if sought {
            currentTime = pending.position
            if shouldPlay { audioPlayer.resume() }
        }
    }
}
