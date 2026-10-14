import XCTest
import GRDB
@testable import Petrichor

final class CrateExportTests: XCTestCase {
    func testTracklistBoundariesAndFallbacks() {
        let row = ExportTrack(title: "Tune", artist: "Artist", label: "Label")
        XCTAssertEqual(TracklistFormatter.render([], numbered: true, includeLabel: false), "")
        XCTAssertEqual(TracklistFormatter.render([row], numbered: true, includeLabel: true), "01. Artist — Tune [Label]")
        XCTAssertTrue(TracklistFormatter.render(Array(repeating: row, count: 99), numbered: true, includeLabel: false).hasPrefix("01. "))
        XCTAssertTrue(TracklistFormatter.render(Array(repeating: row, count: 100), numbered: true, includeLabel: false).hasPrefix("001. "))
        XCTAssertEqual(TracklistFormatter.render([ExportTrack(title: " ", artist: "", label: " ")], numbered: false, includeLabel: true), "Unknown Artist — Untitled")
        XCTAssertEqual(TracklistFormatter.render([ExportTrack(title: "海 & lumière", artist: "Björk")], numbered: false, includeLabel: false), "Björk — 海 & lumière")
    }
    func testProductionWriterSavesTextAndDoesNotCreateFailedXML() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PlaylistManager()
        let snapshot = CrateExportSnapshot(name: "Text", tracks: [ExportTrack(title: "海", artist: "Artist")])
        let text = directory.appendingPathComponent("tracklist.txt")
        try manager.writeExportSnapshot(snapshot, format: .tracklist, to: text)
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), "01. Artist — 海")
        let xml = directory.appendingPathComponent("missing.xml")
        XCTAssertThrowsError(try manager.writeExportSnapshot(snapshot, format: .rekordbox, to: xml))
        XCTAssertFalse(FileManager.default.fileExists(atPath: xml.path))
        XCTAssertThrowsError(try manager.writeExportSnapshot(snapshot, format: .tracklist,
            to: directory.appendingPathComponent("no-directory/tracklist.txt")))
    }

    @MainActor
    func testCaptureUsesSavedOrderAndFreezesLiveEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseManager(databaseURL: directory.appendingPathComponent("library.db"))
        let playlist = Playlist(name: "Saved")
        let audioURL = directory.appendingPathComponent("海 & fixture.wav")
        let pcm: [UInt8] = [82,73,70,70,38,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,128,187,0,0,0,119,1,0,2,0,16,0,100,97,116,97,2,0,0,0,0,0]
        try Data(pcm).write(to: audioURL)
        try await database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO playlists (id, name, type, is_user_editable, is_content_editable, date_created, date_modified) VALUES (?, 'Saved', 'custom', 1, 1, ?, ?)", arguments: [playlist.id.uuidString, Date(), Date()])
            let folder = Folder(url: directory)
            try folder.insert(db)
            let folderID = db.lastInsertedRowID
            for (id, title) in [(1, "Zulu"), (2, "Alpha")] {
                var track = FullTrack(url: id == 1 ? audioURL : directory.appendingPathComponent("missing-\(id).wav"))
                track.trackId = Int64(id)
                track.folderId = folderID
                track.title = title
                track.sampleRate = 44100
                try track.insert(db)
                try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, date_added) VALUES (?, ?, ?, ?)", arguments: [playlist.id.uuidString, id, id, Date()])
            }
        }
        let manager = PlaylistManager()
        manager.libraryManager = LibraryManager(databaseManager: database, startBackgroundTasks: false)
        var sortedView = playlist
        sortedView.tracks = try await database.dbQueue.read { try Track.order(Track.Columns.title).fetchAll($0) }
        manager.playlists = [sortedView]
        let snapshot = try await manager.captureExportSnapshot(playlistID: playlist.id)
        XCTAssertEqual(snapshot.tracks.map(\.title), ["Zulu", "Alpha"])
        XCTAssertEqual(snapshot.tracks.first?.sampleRate, 48000)
        XCTAssertEqual(snapshot.tracks.first?.fileSize, Int64(pcm.count))
        XCTAssertEqual(snapshot.tracks.first?.localURL, audioURL)
        XCTAssertNil(snapshot.tracks.last?.localURL)
        try await database.dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET title = 'Edited' WHERE id = 1")
            try db.execute(sql: "DELETE FROM playlist_tracks WHERE track_id = 2")
        }
        XCTAssertEqual(snapshot.tracks.map(\.title), ["Zulu", "Alpha"])
        let fresh = try await manager.captureExportSnapshot(playlistID: playlist.id)
        XCTAssertEqual(fresh.tracks.map(\.title), ["Edited"])
        try database.sharePlaylist(playlist.id)
        let members = [SyncMember(fileId: "id:unavailable", localTrackID: nil), SyncMember(fileId: nil, localTrackID: 1)]
        let encoded = try JSONEncoder().encode(members)
        try await database.dbQueue.write { db in
            try db.execute(sql: "UPDATE playlist_sync_state SET members = ?, intent = NULL WHERE local_id = ?", arguments: [encoded, playlist.id.uuidString])
        }
        let shared = try await manager.captureExportSnapshot(playlistID: playlist.id)
        XCTAssertEqual(shared.tracks.count, 2)
        XCTAssertEqual(shared.tracks.first?.sharedID, "id:unavailable")
        XCTAssertEqual(shared.tracks.first?.hasDisplayMetadata, false)
        XCTAssertEqual(shared.tracks.last?.title, "Edited")
        let persisted = try await database.dbQueue.read { db in
            try database.syncState(db, localID: playlist.id)?.members
        }
        XCTAssertEqual(persisted, members)
        let smart = Playlist(name: "Smart", criteria: SmartPlaylistCriteria(rules: [
            .init(field: "title", condition: .equals, value: "Edited")
        ], sortBy: "title", sortAscending: true))
        manager.playlists.append(smart)
        let evaluated = try await manager.captureExportSnapshot(playlistID: smart.id)
        XCTAssertEqual(evaluated.tracks.map(\.title), ["Edited"])
        try await database.dbQueue.write { db in try db.execute(sql: "UPDATE tracks SET title = 'Changed again' WHERE id = 1") }
        XCTAssertEqual(evaluated.tracks.map(\.title), ["Edited"])
        let reevaluated = try await manager.captureExportSnapshot(playlistID: smart.id)
        XCTAssertTrue(reevaluated.tracks.isEmpty)


    }

}
