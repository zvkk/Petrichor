import Foundation
import GRDB
import XCTest
@testable import Petrichor

final class PublicationSourceTests: XCTestCase {
    struct TemporaryScope: PublicationScopeAccess {
        func access(bookmark: Data, expectedPath: String) throws -> PublicationScopeLease {
            guard bookmark == Data("fixture".utf8) else { throw PublicationError.unavailableScope }
            return PublicationScopeLease(url: URL(fileURLWithPath: expectedPath))
        }
    }
    var directory: URL!
    var manager: DatabaseManager!
    var service: PublicationSource!
    var trackID: Int64!
    var original: URL { directory.appendingPathComponent("outside/original.wav") }
    var root: URL { directory.appendingPathComponent("paired") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 21, count: 5 * 1024 * 1024 + 17).write(to: original)
        manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("test.db"))
        trackID = try manager.dbQueue.write { db in
            var folder = Folder(url: original.deletingLastPathComponent(), bookmarkData: Data("fixture".utf8))
            try folder.insert(db)
            folder.id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO tracks (folder_id, path, filename, date_added) VALUES (?, ?, ?, ?)", arguments: [folder.id, original.path, original.lastPathComponent, Date()])
            return db.lastInsertedRowID
        }
        let playlist = Playlist(name: "Original membership")
        try manager.savePlaylist(playlist)
        try manager.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO playlist_tracks VALUES (?, ?, ?, ?)", arguments: [playlist.id.uuidString, trackID, 7, Date()])
        }
        try manager.saveSyncPairing(SyncPairing(descriptor: SyncLibraryDescriptor(libraryId: UUID().uuidString.lowercased(), accountId: "account", namespaceId: "namespace", musicFolderId: "id:music"), localRootBookmark: Data("fixture".utf8), localRootPath: root.path, remoteRootPath: "/music"))
        service = PublicationSource(manager: manager, snapshotDirectory: directory.appendingPathComponent("snapshots"), scope: TemporaryScope())
    }
    override func tearDownWithError() throws {
        service = nil; manager = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func membershipRows() throws -> [Row] {
        try manager.dbQueue.read { try Row.fetchAll($0, sql: "SELECT * FROM playlist_tracks") }
    }
    func capture(_ path: String = "copy.wav", consent: Bool = true) async throws -> PublicationID {
        try await service.capture(trackID: trackID, destinationRelativePath: path, confirmedOutsideRootCopy: consent)
    }
    func testConfirmedCopyPreservesOriginalAndDatabaseAndSurvivesReopen() async throws {
        let before = try Data(contentsOf: original)
        let rows = try membershipRows()
        let id = try await capture()
        let record = try XCTUnwrap(service.journal.record(id))
        XCTAssertEqual(record.state, .queued)
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("copy.wav")), before)
        let storedPath = try await manager.dbQueue.read { try String.fetchOne($0, sql: "SELECT path FROM tracks WHERE id=?", arguments: [self.trackID]) }
        XCTAssertEqual(storedPath, original.path)
        let afterRows = try membershipRows()
        XCTAssertEqual(afterRows, rows)
        try service.verifySourceAndCopy(record)
        let reopened = try DatabaseQueue(path: directory.appendingPathComponent("test.db").path)
        XCTAssertEqual(try PublicationJournal(database: reopened).record(id), record)
    }
    func testTraversalAndAbsoluteAndReservedAreRejectedBeforeJournal() async throws {
        for path in ["a/../.crate-sync/x", "/absolute.wav", ".CRATE-SYNC/x", "../x"] {
            do { _ = try await capture(path); XCTFail(path) } catch { XCTAssertEqual(error as? PublicationError, .invalidDestination) }
        }
        XCTAssertTrue(try service.journal.all().isEmpty)
    }
    func testConsentAndUnavailableBookmarkFailClosed() async throws {
        do { _ = try await capture(consent: false); XCTFail() } catch { XCTAssertEqual(error as? PublicationError, .needsConfirmation) }
        try await manager.dbQueue.write { try $0.execute(sql: "UPDATE folders SET bookmark_data = ?", arguments: [Data()]) }
        do { _ = try await capture(); XCTFail() } catch { XCTAssertEqual(error as? PublicationError, .unavailableScope) }
    }
    func testInsideRootRetainsRelativePathAndUnselectedFileIsNotRead() async throws {
        let inside = root.appendingPathComponent("inside.wav")
        try Data("inside".utf8).write(to: inside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("unselected.wav"), withDestinationURL: directory.appendingPathComponent("absent"))
        try await manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE folders SET path = ?", arguments: [self.root.path])
            try db.execute(sql: "UPDATE tracks SET path = ? WHERE id = ?", arguments: [inside.path, self.trackID])
        }
        let id = try await capture("inside.wav", consent: false)
        XCTAssertEqual(try service.journal.record(id)?.state, .queued)
        do { _ = try await capture("renamed.wav", consent: false); XCTFail() } catch {
            XCTAssertEqual(error as? PublicationError, .invalidDestination)
        }
    }
    func testPreCancelledCaptureHasNoEffects() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.capture()
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError { }
        XCTAssertTrue(try service.journal.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.wav").path))
    }
    func testMidCaptureCancellationNeverCopiesOrQueues() async throws {
        service.afterCapture = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await self.capture() }
        do { _ = try await task.value; XCTFail() } catch is CancellationError { }
        XCTAssertEqual(try service.journal.all().map(\.state), [.cancelled])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testChangedFolderOrBookmarkInvalidatesProof() async throws {
        let id = try await capture()
        let record = try XCTUnwrap(service.journal.record(id))
        try await manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE folders SET path = ?", arguments: [self.root.path])
        }
        XCTAssertThrowsError(try service.verifySourceAndCopy(record))
    }
    func testChangingSourceNeverQueues() async throws {
        service.afterCapture = { try Data("changed".utf8).write(to: self.original) }
        do { _ = try await capture(); XCTFail() } catch { XCTAssertEqual(error as? PublicationError, .sourceChanged) }
        XCTAssertEqual(try service.journal.all().map(\.state), [.failed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.wav").path))
    }
    func testMovedSourceNeverQueues() async throws {
        service.afterCapture = { try FileManager.default.moveItem(at: self.original, to: self.original.appendingPathExtension("moved")) }
        do { _ = try await capture(); XCTFail() } catch { }
        XCTAssertEqual(try service.journal.all().map(\.state), [.failed])
    }
    func testCollisionCannotOverwriteAndEqualBytesReuse() async throws {
        let target = root.appendingPathComponent("copy.wav")
        try Data("different".utf8).write(to: target)
        do { _ = try await capture(); XCTFail() } catch { XCTAssertEqual(error as? PublicationError, .needsNewName) }
        XCTAssertEqual(try Data(contentsOf: target), Data("different".utf8))
        try Data(contentsOf: original).write(to: target)
        _ = try await capture()
    }
    func testEscapingSymlinksReject() async throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: original.deletingLastPathComponent())
        do { _ = try await capture("escape/copy.wav"); XCTFail() } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside/copy.wav").path))
    }
    func testRecoveryRollbackAndSnapshotTamper() async throws {
        let id = try await capture()
        let record = try XCTUnwrap(service.journal.record(id))
        enum Rollback: Error { case forced }
        do {
            try await manager.dbQueue.write { db in
                var changed = record; changed.state = .cancelled
                try PublicationJournal.save(changed, in: db)
                throw Rollback.forced
            }
        } catch Rollback.forced { }
        XCTAssertEqual(try service.journal.record(id)?.state, .queued)
        var interrupted = record
        interrupted = Publication(id: UUID(), trackID: record.trackID, generation: 1, snapshot: PublicationSnapshot(trackID: record.trackID, sourcePath: original.path, sourceBookmark: Data(), pairing: record.snapshot.pairing), destination: "another.wav", state: .capturing)
        try service.journal.save(interrupted)
        let reopened = try PublicationJournal(database: DatabaseQueue(path: directory.appendingPathComponent("test.db").path))
        try reopened.recoverInterruptedCaptures()
        XCTAssertEqual(try reopened.record(interrupted.id)?.state, .failed)
        let path = try XCTUnwrap(record.snapshot.snapshotPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try service.verifySnapshot(record))
    }
}
