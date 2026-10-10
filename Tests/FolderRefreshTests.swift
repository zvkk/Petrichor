import Foundation
import GRDB
import XCTest
@testable import Petrichor

final class FolderRefreshTests: XCTestCase {
    private struct LibraryRow: Sendable {
        let id: Int64
        let path: String
        let userData: String

        init(_ row: Row) {
            id = row["id"]
            path = row["path"]
            userData = row["user_data"]
        }
    }
    private var directory: URL!
    private var manager: DatabaseManager!
    private var folder: Folder!
    private var previousHideDuplicates: Any?

    override func setUpWithError() throws {
        previousHideDuplicates = UserDefaults.standard.object(forKey: "hideDuplicateTracks")
        UserDefaults.standard.set(true, forKey: "hideDuplicateTracks")
        // Avoid macOS's /var -> /private/var alias: Foundation normalizes stored
        // file URLs differently from directory enumeration at those paths.
        directory = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("PetrichorTests").appendingPathComponent(UUID().uuidString)
        let music = directory.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("library.db"))
        folder = Folder(url: music)
        try manager.dbQueue.write { db in
            try folder.insert(db)
            folder.id = db.lastInsertedRowID
        }
    }

    override func tearDownWithError() throws {
        if let previousHideDuplicates {
            UserDefaults.standard.set(previousHideDuplicates, forKey: "hideDuplicateTracks")
        } else {
            UserDefaults.standard.removeObject(forKey: "hideDuplicateTracks")
        }
        manager = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testNormalRefreshFindsMissingTracksWithMatchingHash() async throws {
        _ = try addTrack("active.wav", exists: true)
        _ = try addTrack("missing.wav", exists: false, duplicate: true)
        try await manager.updateFolderMetadata(folder.id!)
        let library = LibraryManager(databaseManager: manager, startBackgroundTasks: false)

        let plan = await library.determineFoldersToRefresh()

        XCTAssertEqual(plan.folders.map(\.id), [folder.id])
        XCTAssertTrue(plan.unavailableFolderNames.isEmpty)
    }

    func testMatchingHashWithoutMissingTracksSkipsScan() async throws {
        _ = try addTrack("active.wav", exists: true)
        try await manager.updateFolderMetadata(folder.id!)
        let library = LibraryManager(databaseManager: manager, startBackgroundTasks: false)

        let plan = await library.determineFoldersToRefresh()

        XCTAssertTrue(plan.folders.isEmpty)
    }

    func testRefreshRemovesHiddenMissingTracksAndPreservesUserData() async throws {
        let activeId = try addTrack("active.wav", exists: true)
        _ = try addTrack("missing.wav", exists: false)
        _ = try addTrack("missing-duplicate.wav", exists: false, duplicate: true)
        let playlistId = UUID().uuidString
        try await manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET is_favorite = 1, play_count = 7 WHERE id = ?", arguments: [activeId])
            try db.execute(
                sql: "INSERT INTO playlists (id, name, type, is_user_editable, is_content_editable, date_created, date_modified) VALUES (?, 'Keep', 'custom', 1, 1, ?, ?)",
                arguments: [playlistId, Date(), Date()]
            )
            try db.execute(
                sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, date_added) VALUES (?, ?, 0, ?)",
                arguments: [playlistId, activeId, Date()]
            )
        }

        try await refresh()

        try await manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks"), 1)
            let active = try XCTUnwrap(Track.fetchOne(db, key: activeId))
            XCTAssertTrue(active.isFavorite)
            XCTAssertEqual(active.playCount, 7)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE track_id = ?", arguments: [activeId]), 1)
        }
        try await refresh()
        let count = try await manager.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") }
        XCTAssertEqual(count, 1)
    }

    func testEmptyAccessibleFolderRemovesHiddenMissingTracks() async throws {
        _ = try addTrack("missing.wav", exists: false)
        _ = try addTrack("missing-duplicate.wav", exists: false, duplicate: true)

        try await refresh()

        let count = try await manager.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") }
        XCTAssertEqual(count, 0)
    }

    func testUnavailableFolderPreservesTracks() async throws {
        _ = try addTrack("missing.wav", exists: false, duplicate: true)
        try FileManager.default.removeItem(at: folder.url)

        do {
            try await refresh()
            XCTFail("An unavailable root must fail the scan")
        } catch {
            let count = try await manager.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") }
            XCTAssertEqual(count, 1)
        }
    }

    func testIncompleteScanPreservesMissingTracks() async throws {
        _ = try addTrack("missing.wav", exists: false, duplicate: true)
        _ = try addTrack("unreadable.wav", exists: true)
        let unreadablePath = folder.url.appendingPathComponent("unreadable.wav").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadablePath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadablePath) }

        do {
            try await refresh()
            XCTFail("An incomplete scan must fail before removing tracks")
        } catch {
            let count = try await manager.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") }
            XCTAssertEqual(count, 2)
        }
    }

    /// Opt-in validation against a SQLite backup; never opens the supplied file for writing.
    func testCopiedLibraryRefresh() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["PETRICHOR_REGRESSION_DATABASE"],
              !sourcePath.isEmpty, !sourcePath.hasPrefix("$(") else {
            throw XCTSkip("Set PETRICHOR_REGRESSION_DATABASE to validate a library backup")
        }
        manager = nil
        let copyURL = directory.appendingPathComponent("copied-library.db")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: copyURL)
        manager = try DatabaseManager(databaseURL: copyURL)
        let before = try await manager.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path, json_array(is_favorite, play_count, last_played_date, rating) AS user_data FROM tracks")
                .map(LibraryRow.init)
        }
        let retainedRows = before.filter { FileManager.default.fileExists(atPath: $0.path) }
        let expectedData = Dictionary(uniqueKeysWithValues: retainedRows.map { row in
            (row.id, row.userData)
        })
        // Bookmarks belong to the installed app's signing identity. The test host
        // reads the existing root directly; only the copied database is changed.
        try await manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE folders SET bookmark_data = NULL")
        }
        let library = LibraryManager(databaseManager: manager, startBackgroundTasks: false)
        let plan = await library.determineFoldersToRefresh()
        XCTAssertTrue(plan.unavailableFolderNames.isEmpty)
        XCTAssertFalse(plan.folders.isEmpty)
        for scanFolder in plan.folders {
            folder = scanFolder
            try await refresh()
        }
        let after = try await manager.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path, json_array(is_favorite, play_count, last_played_date, rating) AS user_data FROM tracks")
                .map(LibraryRow.init)
        }
        let actualData = Dictionary(uniqueKeysWithValues: after.map { row in
            (row.id, row.userData)
        })
        // Refresh can also discover valid files added since the snapshot.
        let changedExistingIDs = expectedData.keys.filter { actualData[$0] != expectedData[$0] }
        XCTAssertTrue(changedExistingIDs.isEmpty, "Existing track data changed: \(changedExistingIDs)")
        XCTAssertTrue(after.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        print("Copied library refresh: \(before.count) -> \(after.count) indexed tracks; missing files: 0")
        if let outputPath = ProcessInfo.processInfo.environment["PETRICHOR_REGRESSION_OUTPUT"],
           !outputPath.isEmpty, !outputPath.hasPrefix("$(") {
            guard !FileManager.default.fileExists(atPath: outputPath) else {
                throw CocoaError(.fileWriteFileExists)
            }
            let output = try DatabaseQueue(path: outputPath)
            try manager.dbQueue.backup(to: output)
        }
    }

    private func addTrack(_ name: String, exists: Bool, duplicate: Bool = false) throws -> Int64 {
        let url = folder.url.appendingPathComponent(name)
        if exists { try makeWAV().write(to: url) }
        return try manager.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO tracks (folder_id, path, filename, title, artist, album, composer, genre, year, duration, format, date_added, is_duplicate) VALUES (?, ?, ?, ?, 'Artist', 'Album', 'Composer', 'Genre', '2026', 0.1, 'wav', ?, ?)",
                arguments: [folder.id, url.path, name, name, Date(), duplicate]
            )
            return db.lastInsertedRowID
        }
    }

    private func refresh() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.refreshFolder(folder, manageActivityIndicator: false) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func makeWAV() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func uint16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func uint32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        text("RIFF"); uint32(36 + 8820); text("WAVE")
        text("fmt "); uint32(16); uint16(1); uint16(1)
        uint32(44100); uint32(88200); uint16(2); uint16(16)
        text("data"); uint32(8820)
        data.append(Data(repeating: 0, count: 8820))
        return data
    }
}
