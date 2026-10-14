import XCTest
import GRDB
@testable import Petrichor

/// Real facade, fake existing backend boundary. Loads can remain suspended indefinitely.
final class PreviewBackend: PlaybackBackend {
    weak var backendDelegate: PlaybackBackendDelegate?
    var volume: Float = 0.7
    var state: AudioPlayerState = .stopped
    var currentPlaybackProgress = 0.0
    var duration = 300.0
    var currentStreamFormat: StreamFormat? { nil }
    var currentEntryId: AudioEntryId?
    var entries: [QueueEntry] = []
    var queue: [AudioEntryId] { entries.map(\.entryId) }
    var hasQueuedSuccessor: Bool { false }
    var events: [String] = []
    var seekSucceeds = true
    var duringSeek: (() -> Void)?
    func queueIndex(of entryId: AudioEntryId) -> Int? { queue.firstIndex(of: entryId) }
    func setQueue(_ entries: [QueueEntry], startingAt index: Int, startPaused: Bool) {
        self.entries = entries; currentEntryId = entries[index].entryId
        state = .ready; events.append("load\(entries[index].url.deletingPathExtension().lastPathComponent)")
    }
    func ready() {
        let old = state; state = .paused
        events.append("ready\(name)")
        backendDelegate?.backendStateChanged(entryId: currentEntryId, with: .paused, previous: old)
    }
    private var name: String { entries.first(where: { $0.entryId == currentEntryId })?.url.deletingPathExtension().lastPathComponent ?? "?" }
    func seek(to time: Double) -> Bool {
        events.append("seek\(name)"); currentPlaybackProgress = time
        let action = duringSeek; duringSeek = nil; action?()
        return seekSucceeds
    }
    func pause() { state = .paused }
    func resume() { events.append("play\(name)"); state = .playing }
    func stop() { state = .stopped }
    func togglePlayPause() { state == .playing ? pause() : resume() }
    func releaseForIdle() {}
    func resumeFromIdle() {}
    func seekForward(_ seconds: Double) -> Bool { seek(to: currentPlaybackProgress + seconds) }
    func seekBackward(_ seconds: Double) -> Bool { seek(to: currentPlaybackProgress - seconds) }
    func playStream(url: URL, entryId: AudioEntryId) { currentEntryId = entryId }
    func insert(_ entry: QueueEntry, at index: Int) { entries.insert(entry, at: index) }
    func append(_ entry: QueueEntry) { entries.append(entry) }
    func insertNext(_ entry: QueueEntry) { entries.append(entry) }
    func move(from: Int, to: Int) {}
    func removeQueueEntry(at index: Int) { entries.remove(at: index) }
    func removeQueueEntry(id: AudioEntryId) { entries.removeAll { $0.entryId == id } }
    func clearQueue() { entries = [] }
    func playQueueEntry(at index: Int, startPaused: Bool) { currentEntryId = entries[index].entryId }
    func shuffleQueue() {}
    var metadata: NowPlayingMetadata?
    var metadataUpdates = 0
    func setNowPlayingMetadata(_ metadata: NowPlayingMetadata?) {
        self.metadata = metadata
        metadataUpdates += 1
    }
    func setStereoWidening(enabled: Bool) {}
    func isStereoWideningEnabled() -> Bool { false }
    func setEQEnabled(_ enabled: Bool) {}
    func isEQEnabled() -> Bool { false }
    func applyEQPreset(_ preset: EqualizerPreset) {}
    func applyEQCustom(gains: [Float]) {}
    func setPreamp(_ gain: Float) {}
    func getPreamp() -> Float { 0 }
    func setCrossfadeEnabled(_ enabled: Bool) {}
    func isCrossfadeEnabled() -> Bool { false }
    func setCrossfadeDuration(_ duration: TimeInterval) {}
    func getCrossfadeDuration() -> TimeInterval { 3 }
    var crossfadeDurationRange: ClosedRange<TimeInterval> { 0...10 }
    func setReplayGainMode(_ mode: ReplayGainMode) {}
    func getReplayGainMode() -> ReplayGainMode { .auto }
    func setReplayGainPreamp(_ decibels: Float) {}
    func getReplayGainPreamp() -> Float { 0 }
    var replayGainPreampRange: ClosedRange<Float> { -20...20 }
}

@MainActor
final class PreviewSessionTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var backend: PreviewBackend!
    private var player: PlaybackManager!
    private var playlists: PlaylistManager!
    private var tracks: [Track] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try DatabaseManager(databaseURL: root.appendingPathComponent("library.db"))
        let library = LibraryManager(databaseManager: database, startBackgroundTasks: false)
        playlists = PlaylistManager()
        backend = PreviewBackend()
        player = PlaybackManager(libraryManager: library, playlistManager: playlists, engine: PlaybackEngine(backend: backend))
        playlists.setAudioPlayer(player)
        playlists.libraryManager = library
        var folder = Folder(url: root)
        try database.dbQueue.write { db in
            try folder.insert(db)
            folder.id = db.lastInsertedRowID
        }
        tracks = try ["A", "B", "C", "D"].map { name in
            let url = root.appendingPathComponent("\(name).wav")
            try Data().write(to: url)
            var track = Track(url: url)
            track.trackId = try database.dbQueue.write { db in
                try db.execute(sql: "INSERT INTO tracks (folder_id, path, filename, title, artist, album, composer, genre, year, duration, format, date_added) VALUES (?, ?, ?, ?, 'Artist', 'Album', 'Composer', 'Genre', '2026', 300, 'wav', ?)", arguments: [folder.id, url.path, url.lastPathComponent, name, Date()])
                return db.lastInsertedRowID
            }
            return track
        }
        playlists.installRestoredQueue([tracks[0], tracks[3]], cursor: 0, source: .folder, playlist: nil)
        player.startQueue(at: 0)
        player.currentTime = 37
        backend.currentPlaybackProgress = 37
        backend.state = .paused
        backend.events = []
    }

    override func tearDown() async throws {
        player.audioPlayer.delegate = nil
        await drain()
        try await database.dbQueue.write { _ in }
        await drain()
        player = nil; playlists = nil; database = nil; backend = nil; tracks = []
        try FileManager.default.removeItem(at: root)
    }

    // Delegate callbacks deliberately enqueue onto the real main queue.
    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testReadySeekPlayOrderAndRepeatedPreviewRestoresOriginalPaused() async {
        player.previewSession.begin(track: tracks[1])
        XCTAssertEqual(backend.events, ["loadB"])
        XCTAssertEqual(playlists.currentQueue.map(\.url), [tracks[0].url, tracks[3].url])
        backend.ready(); await drain()
        XCTAssertEqual(backend.events, ["loadB", "readyB", "seekB", "playB"])
        XCTAssertEqual(player.currentTime, 60)
        player.previewSession.begin(track: tracks[2])
        backend.ready(); await drain()
        player.previewSession.end()
        XCTAssertEqual(player.currentTrack?.url, tracks[0].url)
        XCTAssertEqual(playlists.currentQueueIndex, 0)
        XCTAssertEqual(playlists.currentQueueSource, .folder)
        XCTAssertEqual(player.currentTime, 37)
        backend.ready(); await drain()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(backend.state, .paused)
        XCTAssertEqual(backend.currentPlaybackProgress, 37)
        XCTAssertFalse(backend.events.contains("playA"))
    }

    func testPauseDuringSuspendedReadyNeverResumesBeforeSeek() async {
        player.previewSession.begin(track: tracks[1])
        player.togglePlayPause()
        XCTAssertEqual(backend.events, ["loadB"])
        backend.ready(); await drain()
        XCTAssertEqual(backend.events, ["loadB", "readyB", "seekB"])
        XCTAssertFalse(player.isPlaying)
        player.togglePlayPause()
        XCTAssertEqual(backend.events.last, "playB")
    }

    func testDeliberateFavouriteUpdateSurvivesRestoration() async {
        player.previewSession.begin(track: tracks[0])
        var edited = tracks[0]
        edited.isFavorite = true
        await playlists.handleTrackPropertyUpdate(edited)
        player.previewSession.end()
        XCTAssertEqual(player.currentTrack?.isFavorite, true)
        XCTAssertEqual(playlists.currentQueue.first?.isFavorite, true)
        XCTAssertEqual(playlists.currentQueue.map(\.url), [tracks[0].url, tracks[3].url])
    }

    func testDecodedDurationAndInvalidStoredSettingsUseSafeStart() async {
        let defaults = UserDefaults.standard
        let keys = ["previewFraction", "previewMinSeconds", "previewMaxSeconds"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(Double.nan, forKey: keys[0])
        player.previewSession.begin(track: tracks[1])
        backend.ready(); await drain()
        XCTAssertEqual(backend.currentPlaybackProgress, 0)
        defaults.set(0.2, forKey: keys[0]); defaults.set(20.0, forKey: keys[1]); defaults.set(75.0, forKey: keys[2])
        backend.duration = 21
        player.previewSession.begin(track: tracks[2])
        backend.ready(); await drain()
        XCTAssertEqual(backend.currentPlaybackProgress, 0)
    }

    func testRestoreReadySupersededByOrdinaryPlayCannotSeekIt() async {
        player.previewSession.begin(track: tracks[1])
        player.previewSession.end()
        let restoreID = player.currentEntryId!
        playlists.playTrack(tracks[3])
        backend.events = []
        player.audioPlayerStateChanged(player: player.audioPlayer, entryId: restoreID, with: .paused, previous: .ready)
        await drain()
        XCTAssertTrue(backend.events.isEmpty)
        XCTAssertEqual(player.currentTrack?.url, tracks[3].url)
    }

    func testOldReadyAndEOFCannotChangeOrdinaryReplacement() async {
        player.previewSession.begin(track: tracks[1])
        let stale = player.currentEntryId!
        playlists.playTrack(tracks[3])
        let ordinary = player.currentEntryId
        backend.events = []
        player.audioPlayerStateChanged(player: player.audioPlayer, entryId: stale, with: .paused, previous: .ready)
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: stale, stopReason: .eof, progress: 300, duration: 300)
        await drain()
        XCTAssertEqual(player.currentEntryId, ordinary)
        XCTAssertEqual(player.currentTrack?.url, tracks[3].url)
        XCTAssertNil(player.purpose(for: stale))
        XCTAssertTrue(backend.events.isEmpty)
        player.previewSession.end()
        XCTAssertEqual(player.currentEntryId, ordinary)
    }

    func testReentrantSeekReplacementNeverResumesNewOrdinaryTrack() async {
        player.previewSession.begin(track: tracks[1])
        backend.duringSeek = { [self] in playlists.playTrack(tracks[3]) }
        backend.ready(); await drain()
        XCTAssertEqual(backend.events, ["loadB", "readyB", "seekB", "loadD"])
        XCTAssertFalse(player.isPreviewing)
    }

    func testFailedSeekDoesNotPlayAndPreviewEOFDoesNotAdvance() async {
        backend.seekSucceeds = false
        player.previewSession.begin(track: tracks[1])
        backend.ready(); await drain()
        XCTAssertFalse(backend.events.contains("playB"))
        let id = player.currentEntryId!
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: id, stopReason: .eof, progress: 300, duration: 300)
        await drain()
        XCTAssertEqual(player.currentEntryId, id)
        XCTAssertEqual(playlists.currentQueueIndex, 0)
        XCTAssertFalse(player.isPlaying)
        playlists.playNextTrack(); playlists.playPreviousTrack()
        XCTAssertEqual(player.currentEntryId, id)
    }

    func testQueueEditEndsPreviewBeforeApplyingEdit() async {
        player.previewSession.begin(track: tracks[1])
        playlists.addToQueue(tracks[2])
        XCTAssertFalse(player.isPreviewing)
        XCTAssertEqual(playlists.currentQueue.map(\.url), [tracks[0].url, tracks[3].url, tracks[2].url])
        XCTAssertEqual(player.currentTrack?.url, tracks[0].url)
        player.previewSession.begin(track: tracks[1])
        playlists.toggleShuffle()
        XCTAssertFalse(player.isPreviewing)
        XCTAssertTrue(playlists.isShuffleEnabled)
    }

    func testPreviewNeverCreditsHistoryAndOrdinaryEOFCreditsActualTrack() async throws {
        player.previewSession.begin(track: tracks[1])
        XCTAssertFalse(player.canPersistOrdinarySession)
        let audition = player.currentEntryId!
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: audition, stopReason: .eof, progress: 300, duration: 300)
        await drain()
        playlists.playTrack(tracks[3])
        XCTAssertTrue(player.canPersistOrdinarySession)
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: audition, stopReason: .eof, progress: 300, duration: 300)
        await drain()
        let previewCount = try await database.getTrackPlayCount(trackId: tracks[1].trackId!)
        XCTAssertEqual(previewCount ?? 0, 0)
        let previewTrackID = tracks[1].trackId!
        let lastPlayed: Date? = try await database.dbQueue.read { db in
            try Date.fetchOne(db, sql: "SELECT last_played_date FROM tracks WHERE id = ?", arguments: [previewTrackID])
        }
        XCTAssertNil(lastPlayed)
        let ordinaryTrackID = tracks[3].trackId!
        let credited = expectation(forNotification: .trackPlayCountUpdated, object: nil) { note in
            note.userInfo?["trackId"] as? Int64 == ordinaryTrackID
        }
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: player.currentEntryId!, stopReason: .eof, progress: 300, duration: 300)
        await fulfillment(of: [credited], timeout: 3)
        let ordinaryCount = try await database.getTrackPlayCount(trackId: tracks[3].trackId!)
        XCTAssertEqual(ordinaryCount, 1)
    }

    func testRadioExclusionAndStaleUserActionErrorAndStart() async {
        XCTAssertFalse(player.canPreview(Track(url: root)))
        player.previewSession.begin(track: tracks[1])
        let stale = player.currentEntryId!
        playlists.playTrack(tracks[3])
        player.currentTime = 19
        player.isPlaying = true
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: stale, stopReason: .userAction, progress: 0, duration: 300)
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: stale, stopReason: .error, progress: 0, duration: 300)
        player.audioPlayerDidStartPlaying(player: player.audioPlayer, with: stale)
        await drain()
        XCTAssertEqual(player.currentTime, 19)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentTrack?.url, tracks[3].url)
        player.currentStation = RadioStation(name: "Radio", streamURL: "https://example.org/stream")
        XCTAssertFalse(player.canPreview(tracks[1]))
        player.previewSession.begin(track: tracks[1])
        XCTAssertFalse(player.isPreviewing)
    }

    func testQueueRemoveAndReorderAndRepeatRestoreBeforeEdit() async {
        player.previewSession.begin(track: tracks[1])
        playlists.moveInQueue(from: 1, to: 0)
        XCTAssertFalse(player.isPreviewing)
        XCTAssertEqual(playlists.currentQueue.map(\.url), [tracks[3].url, tracks[0].url])
        player.previewSession.begin(track: tracks[1])
        playlists.removeFromQueue(at: 0)
        XCTAssertFalse(player.isPreviewing)
        XCTAssertEqual(playlists.currentQueue.map(\.url), [tracks[0].url])
        player.previewSession.begin(track: tracks[1])
        playlists.toggleRepeatMode()
        XCTAssertFalse(player.isPreviewing)
        XCTAssertEqual(playlists.repeatMode, .all)
    }

    func testRepeatedLargeQueueRebuildsRetireUnstartedRowsAndReleaseArtwork() async {
        var artworkTrack = tracks[0]
        artworkTrack.setArtworkData(Data(repeating: 1, count: 1024))
        let largeQueue = Array(repeating: artworkTrack, count: 2_000)
        let originalID = player.currentEntryId!
        for _ in 0..<30 {
            player.rebuildQueueMirror(for: largeQueue)
            XCTAssertEqual(player.entryPurposes.count, largeQueue.count + 1)
            XCTAssertEqual(player.entryTracks.count, largeQueue.count + 1)
            XCTAssertTrue(player.entryTracks.values.allSatisfy { $0.artworkData == nil })
        }
        player.currentEntryId = nil
        backend.currentEntryId = nil
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: originalID,
            stopReason: .userAction, progress: 37, duration: 300)
        await drain()
        XCTAssertNil(player.purpose(for: originalID))
        player.rebuildQueueMirror(for: largeQueue)
        XCTAssertEqual(player.entryTracks.count, largeQueue.count)
    }

    func testLateOrdinaryEOFAfterNewSessionCreditsOriginalAndReleasesRecord() async throws {
        let ordinaryID = player.currentEntryId!
        let trackID = tracks[0].trackId!
        player.previewSession.begin(track: tracks[1])
        let previewID = player.currentEntryId!
        playlists.playTrack(tracks[3])
        let replacementID = player.currentEntryId
        let credited = expectation(forNotification: .trackPlayCountUpdated, object: nil) { note in
            note.userInfo?["trackId"] as? Int64 == trackID
        }
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: ordinaryID,
            stopReason: .eof, progress: 300, duration: 300)
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: previewID,
            stopReason: .eof, progress: 300, duration: 300)
        await fulfillment(of: [credited], timeout: 3)
        await drain()
        let count = try await database.getTrackPlayCount(trackId: trackID)
        let previewCount = try await database.getTrackPlayCount(trackId: tracks[1].trackId!)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(previewCount ?? 0, 0)
        XCTAssertEqual(player.currentEntryId, replacementID)
        XCTAssertNil(player.purpose(for: ordinaryID))
        XCTAssertNil(player.purpose(for: previewID))
    }

    func testStartedSuccessorRetainedBeforeDeferredStartAndReleasedAfterLateFinish() async throws {
        let successorID = player.mirror[1].entryId
        backend.currentEntryId = successorID
        backend.backendDelegate?.backendDidStartPlaying(with: successorID)
        // The UI start callback has not drained, but this occurrence really started.
        playlists.playTrack(tracks[2])
        XCTAssertEqual(player.purpose(for: successorID), .ordinary)
        await drain()
        let trackID = tracks[3].trackId!
        let credited = expectation(forNotification: .trackPlayCountUpdated, object: nil) { note in
            note.userInfo?["trackId"] as? Int64 == trackID
        }
        player.audioPlayerDidFinishPlaying(player: player.audioPlayer, entryId: successorID,
            stopReason: .eof, progress: 300, duration: 300)
        await fulfillment(of: [credited], timeout: 3)
        XCTAssertNil(player.purpose(for: successorID))
        XCTAssertEqual(player.currentTrack?.url, tracks[2].url)
    }

    func testEndPreviewWithoutOriginalClearsBackendMetadataAndAuditionOwnership() {
        player.currentTrack = nil
        player.currentEntryId = nil
        player.previewSession.begin(track: tracks[1])
        XCTAssertEqual(backend.metadata?.title, tracks[1].title)
        player.previewSession.end()
        XCTAssertNil(backend.metadata)
        XCTAssertTrue(player.mirror.isEmpty)
        XCTAssertTrue(player.unmirroredTracks.isEmpty)
        XCTAssertNil(player.injectedNext)
    }

    func testMissingRestoreDoesNotSkipAndMissingPreviewIsRejected() async throws {
        player.previewSession.begin(track: tracks[1])
        try FileManager.default.removeItem(at: tracks[0].url)
        player.previewSession.end()
        XCTAssertEqual(player.currentTrack?.url, tracks[0].url)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(playlists.currentQueueIndex, 0)
        XCTAssertFalse(player.canPreview(tracks[0]))
        XCTAssertEqual(backend.metadata?.title, tracks[0].title)
        XCTAssertTrue(player.mirror.isEmpty)
        XCTAssertTrue(player.unmirroredTracks.isEmpty)
        XCTAssertNil(player.injectedNext)
    }
}
