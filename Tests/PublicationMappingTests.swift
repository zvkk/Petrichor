import Foundation
import GRDB
import XCTest
@testable import Petrichor

final class PublicationMappingTests: PublicationTestCase {
    func testPublicationKeepsOriginalInTwoCratesAndBlocksUnvalidatedIntent() async throws {
        let playlists = [Playlist(name: "One"), Playlist(name: "Two")]
        for playlist in playlists {
            try manager.savePlaylist(playlist)
            try await manager.dbQueue.write { db in
                try PlaylistTrack(playlistId: playlist.id.uuidString, trackId: trackID, position: 0, dateAdded: Date()).insert(db)
            }
            try manager.sharePlaylist(playlist.id)
        }
        let id = try await service.capture(trackID: trackID, destinationRelativePath: "published.wav", confirmedOutsideRootCopy: true)
        let record = try XCTUnwrap(service.journal.record(id))
        let fake = PublicationServiceTests.Fake(record)
        await PublicationService(source: service, transport: { _ in fake }).run(id: id)
        XCTAssertEqual(try manager.syncMapping(fileID: "id:verified"), trackID)
        for playlist in playlists {
            let intent = try XCTUnwrap(manager.syncIntent(playlist.id))
            XCTAssertThrowsError(try manager.materializeSyncIntent(playlist.id, generation: intent.generation, resolved: [trackID: "id:verified"]))
            let members = try await manager.dbQueue.read { try Int64.fetchAll($0, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id=?", arguments: [playlist.id.uuidString]) }
            XCTAssertEqual(members, [trackID])
        }
        let path = try await manager.dbQueue.read { try String.fetchOne($0, sql: "SELECT path FROM tracks WHERE id=?", arguments: [trackID]) }
        XCTAssertEqual(path, original.path)
    }
}

extension PublicationMappingTests {
    private func addNative(_ path: URL) throws -> Int64 {
        try manager.dbQueue.write { db in
            let folderID: Int64
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE path=?", arguments: [path.deletingLastPathComponent().path]) { folderID = existing }
            else {
                var folder = Folder(url: path.deletingLastPathComponent(), bookmarkData: Data("fixture".utf8))
                try folder.insert(db)
                folderID = db.lastInsertedRowID
            }
            try db.execute(sql: "INSERT INTO tracks (folder_id,path,filename,date_added) VALUES (?,?,?,?)", arguments: [folderID, path.path, path.lastPathComponent, Date()])
            return db.lastInsertedRowID
        }
    }
    private func sharedCrate(_ ids: [Int64]) throws -> Playlist {
        let playlist = Playlist(name: "Shared")
        try manager.savePlaylist(playlist)
        try manager.dbQueue.write { db in
            for (index, id) in ids.enumerated() {
                try PlaylistTrack(playlistId: playlist.id.uuidString, trackId: id, position: index, dateAdded: Date()).insert(db)
            }
        }
        try manager.sharePlaylist(playlist.id)
        return playlist
    }
    private func nativeIDs(_ playlist: Playlist) throws -> [Int64] {
        try manager.dbQueue.read { try Int64.fetchAll($0, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id=? ORDER BY position", arguments: [playlist.id.uuidString]) }
    }
    private func editMetadata(_ playlist: Playlist) throws {
        try manager.dbQueue.write { try manager.capturePlaylistIntent($0, playlistID: playlist.id, mutation: .metadata) }
    }
    private func publish(_ track: Int64, destination: String = "published.wav", fileID: String = "id:verified") async throws -> Publication {
        let id = try await service.capture(trackID: track, destinationRelativePath: destination, confirmedOutsideRootCopy: true)
        let record = try XCTUnwrap(service.journal.record(id))
        let fake = PublicationServiceTests.Fake(record)
        await fake.setRemote(PublicationRemoteProof(fileID: fileID, contentHash: record.snapshot.dropboxHash!, size: UInt64(record.snapshot.sourceIdentity!.size)))
        await PublicationService(source: service, transport: { _ in fake }).run(id: id)
        let completed = try XCTUnwrap(service.journal.record(id))
        XCTAssertEqual(completed.state, .completed)
        return completed
    }
    private func materialize(_ playlist: Playlist, track: Int64) async throws -> Bool {
        let intent = try XCTUnwrap(manager.syncIntent(playlist.id))
        let resolved = [track: "id:verified"]
        let validations = try await manager.validatePublicationIntent(playlist.id, generation: intent.generation, resolved: resolved, scope: TemporaryScope())
        return try manager.materializeSyncIntent(playlist.id, generation: intent.generation, resolved: resolved, publicationValidations: validations)
    }
    func testFreshProofUnblocksAndOriginalMutationSurvivesRestart() async throws {
        let crate = try sharedCrate([trackID])
        let record = try await publish(trackID)
        let done = try await materialize(crate, track: trackID)
        XCTAssertTrue(done)
        XCTAssertEqual(try manager.syncStates().first { $0.localID == crate.id }?.members.first?.fileId, "id:verified")
        try editMetadata(crate)
        try Data("changed original".utf8).write(to: original)
        manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("test.db"))
        do { _ = try await materialize(crate, track: trackID); XCTFail("changed original accepted") } catch {}
        XCTAssertEqual(try nativeIDs(crate), [trackID])
        XCTAssertEqual(try PublicationJournal(database: manager.dbQueue).record(record.id)?.state, .completed)
        XCTAssertEqual(try manager.syncStates().first { $0.localID == crate.id }?.members.first?.fileId, "id:verified")
        XCTAssertNotNil(try manager.syncIntent(crate.id))
    }
    func testCopyMutationAndStaleReceiptFailClosed() async throws {
        let crate = try sharedCrate([trackID])
        _ = try await publish(trackID)
        let intent = try XCTUnwrap(manager.syncIntent(crate.id))
        let validations = try await manager.validatePublicationIntent(crate.id, generation: intent.generation, resolved: [trackID: "id:verified"], scope: TemporaryScope())
        try Data("copy tamper".utf8).write(to: root.appendingPathComponent("published.wav"))
        XCTAssertThrowsError(try manager.materializeSyncIntent(crate.id, generation: intent.generation, resolved: [trackID: "id:verified"], publicationValidations: validations))
        XCTAssertEqual(try nativeIDs(crate), [trackID])
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
        do { _ = try await materialize(crate, track: trackID); XCTFail("copy mutation accepted") } catch {}
    }
    func testTwoOriginalsOneRemoteAndScannerCopyNeverMigrateMembership() async throws {
        let other = directory.appendingPathComponent("outside/second.flac")
        try FileManager.default.copyItem(at: original, to: other)
        let second = try addNative(other)
        let firstCrate = try sharedCrate([trackID])
        let secondCrate = try sharedCrate([second])
        _ = try await publish(trackID)
        let secondPublication = try await publish(second)
        let scanID = try addNative(root.appendingPathComponent("published.wav"))
        try manager.saveSyncMapping(fileID: "id:verified", trackID: scanID, hash: "untrusted scanner", expectedPath: root.appendingPathComponent("published.wav").path)
        let firstDone = try await materialize(firstCrate, track: trackID)
        let secondDone = try await materialize(secondCrate, track: second)
        XCTAssertTrue(firstDone); XCTAssertTrue(secondDone)
        try manager.projectSyncRevisions()
        XCTAssertEqual(try nativeIDs(firstCrate), [trackID])
        XCTAssertEqual(try nativeIDs(secondCrate), [second])
        try editMetadata(firstCrate)
        try editMetadata(secondCrate)
        try Data("only first original changed".utf8).write(to: original)
        do { try await refresh(secondPublication); XCTFail("changed first original accepted") } catch {}
        let secondStillValid = try await materialize(secondCrate, track: second)
        XCTAssertTrue(secondStillValid)
        do { _ = try await materialize(firstCrate, track: trackID); XCTFail("changed first original materialized") } catch {}
        try manager.invalidateSyncMapping("id:verified")
        XCTAssertEqual(try nativeIDs(firstCrate), [trackID])
        XCTAssertEqual(try nativeIDs(secondCrate), [second])
        try editMetadata(firstCrate)
        do { _ = try await materialize(firstCrate, track: trackID); XCTFail("durably blocked proof accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testKnownRemoteWithoutLocalIDStillRequiresPublicationProof() async throws {
        let crate = try sharedCrate([trackID])
        _ = try await publish(trackID)
        _ = try await materialize(crate, track: trackID)
        try editMetadata(crate)
        try await manager.dbQueue.write { db in
            let intent = try XCTUnwrap(manager.syncState(db, localID: crate.id)?.intent)
            var changed = intent
            changed.members = [SyncMember(fileId: "id:verified", localTrackID: nil)]
            try db.execute(sql: "UPDATE playlist_sync_state SET intent=? WHERE local_id=?", arguments: [try JSONEncoder().encode(changed), crate.id.uuidString])
        }
        let intent = try XCTUnwrap(manager.syncIntent(crate.id))
        XCTAssertThrowsError(try manager.materializeSyncIntent(crate.id, generation: intent.generation, resolved: [:]))
        try Data("mutated".utf8).write(to: original)
        do {
            _ = try await manager.validatePublicationIntent(crate.id, generation: intent.generation, resolved: [:], scope: TemporaryScope())
            XCTFail("known remote bypassed original validation")
        } catch {}
        XCTAssertEqual(try nativeIDs(crate), [trackID])
    }
    func testRelocationAndCancelledCompletionLeaveNoMapping() async throws {
        let crate = try sharedCrate([trackID])
        let id = try await service.capture(trackID: trackID, destinationRelativePath: "published.wav", confirmedOutsideRootCopy: true)
        let record = try XCTUnwrap(service.journal.record(id))
        let source = service!
        let receipt = try await Task.detached { try source.validatePublication(record) }.value
        try service.journal.cancel(id)
        XCTAssertThrowsError(try service.journal.complete(record, proof: PublicationRemoteProof(fileID: "id:verified", contentHash: record.snapshot.dropboxHash!, size: UInt64(record.snapshot.sourceIdentity!.size)), validation: receipt))
        XCTAssertNil(try manager.syncMapping(fileID: "id:verified"))
        XCTAssertEqual(try nativeIDs(crate), [trackID])
    }
}

private final class PublicationMappingProtocol: URLProtocol, @unchecked Sendable {
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension PublicationMappingTests {
    private func refresh(_ record: Publication) async throws {
        let proof = try XCTUnwrap(record.verifiedMapping)
        PublicationMappingProtocol.body = try JSONSerialization.data(withJSONObject: [".tag": "file", "id": proof.fileID, "path_display": "/music/\(record.destination)", "content_hash": proof.contentHash, "size": proof.size])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicationMappingProtocol.self]
        let client = DropboxPlaylistTransport(accessToken: "fixture", session: URLSession(configuration: configuration))
        defer { client.session.invalidateAndCancel() }
        let pairing = try XCTUnwrap(manager.syncPairing())
        let mapped = try await DropboxPlaylistSyncCoordinator.refreshRemoteMapping(proof.fileID, root: root, pairing: pairing, client: client, db: manager, scope: TemporaryScope())
        guard mapped else { throw PlaylistSyncError.mappingBlocked }
    }
    func testFreshRecaptureSupersedesStaleHistoryAndOldRemoteCannotPoisonNewProof() async throws {
        let old = try await publish(trackID)
        let originalBytes = try Data(contentsOf: original)
        try Data("changed then restored".utf8).write(to: original)
        try originalBytes.write(to: original)
        try manager.blockPublication(old)
        let fresh = try await publish(trackID)
        XCTAssertNotEqual(old.snapshot.sourceIdentity, fresh.snapshot.sourceIdentity)
        try await refresh(fresh)
        let firstCrate = try sharedCrate([trackID])
        let done = try await materialize(firstCrate, track: trackID)
        XCTAssertTrue(done)
        let newer = try await publish(trackID, destination: "new.wav", fileID: "id:new")
        try manager.invalidateSyncMapping("id:verified")
        try await refresh(newer)
        let secondCrate = try sharedCrate([trackID])
        let intent = try XCTUnwrap(manager.syncIntent(secondCrate.id))
        let receipts = try await manager.validatePublicationIntent(secondCrate.id, generation: intent.generation, resolved: [trackID: "id:new"], scope: TemporaryScope())
        XCTAssertTrue(try manager.materializeSyncIntent(secondCrate.id, generation: intent.generation, resolved: [trackID: "id:new"], publicationValidations: receipts))
        try editMetadata(firstCrate)
        do { _ = try await materialize(firstCrate, track: trackID); XCTFail("old wire reference silently retargeted") } catch {}
        XCTAssertEqual(try nativeIDs(firstCrate), [trackID])
        XCTAssertEqual(try nativeIDs(secondCrate), [trackID])
    }
    func testAliasPromotionAndSourceCopyRelocationPreserveOriginals() async throws {
        let crate = try sharedCrate([trackID])
        _ = try await publish(trackID)
        let copy = root.appendingPathComponent("published.wav")
        let scanned = try addNative(copy)
        try await manager.dbQueue.write { try $0.execute(sql: "UPDATE tracks SET format='WAV', duration=60, title='Fixture', artist='Artist', album='Album', composer='Composer', genre='Genre', year='2026', lossless=1") }
        try await manager.dbQueue.write { try $0.execute(sql: "UPDATE tracks SET format='DSF' WHERE id=?", arguments: [scanned]) }
        await manager.detectAndMarkDuplicates()
        let promoted = try await manager.dbQueue.read { try Int64.fetchOne($0, sql: "SELECT primary_track_id FROM tracks WHERE id=?", arguments: [trackID]) }
        XCTAssertEqual(promoted, scanned)
        try manager.saveSyncMapping(fileID: "id:verified", trackID: scanned, hash: "scanner")
        XCTAssertEqual(try manager.syncMapping(fileID: "id:verified"), trackID)
        let moved = root.appendingPathComponent("moved.wav")
        try FileManager.default.moveItem(at: copy, to: moved)
        do { _ = try await materialize(crate, track: trackID); XCTFail("copy relocation accepted") } catch {}
        XCTAssertEqual(try nativeIDs(crate), [trackID])
        try FileManager.default.moveItem(at: original, to: original.deletingLastPathComponent().appendingPathComponent("moved.wav"))
        XCTAssertEqual(try nativeIDs(crate), [trackID])
    }
}

extension PublicationMappingTests {
    func testMappingFailureRollsBackCompletionAndProofAtomically() async throws {
        let id = try await service.capture(trackID: trackID, destinationRelativePath: "published.wav", confirmedOutsideRootCopy: true)
        let record = try XCTUnwrap(service.journal.record(id))
        try await manager.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_publication_mapping BEFORE INSERT ON playlist_sync_mapping BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END")
        }
        let source = service!
        let receipt = try await Task.detached { try source.validatePublication(record) }.value
        XCTAssertThrowsError(try service.journal.complete(record, proof: PublicationRemoteProof(fileID: "id:verified", contentHash: record.snapshot.dropboxHash!, size: UInt64(record.snapshot.sourceIdentity!.size)), validation: receipt))
        XCTAssertEqual(try service.journal.record(id)?.state, .queued)
        XCTAssertNil(try service.journal.record(id)?.verifiedMapping)
        XCTAssertNil(try manager.syncMapping(fileID: "id:verified"))
    }
}

extension PublicationMappingTests {
    func testAutomaticMissingFileCleanupRetainsPublishedOriginalAndRemovesUnrelatedTrack() async throws {
        let unrelatedPath = directory.appendingPathComponent("outside/unrelated.m4a")
        try Data("different encoding".utf8).write(to: unrelatedPath)
        let unrelated = try addNative(unrelatedPath)
        let crate = try sharedCrate([trackID, unrelated])
        _ = try await publish(trackID)
        try await manager.dbQueue.write { try $0.execute(sql: "UPDATE tracks SET format='WAV', duration=60, title='Fixture', artist='Artist', album='Album', composer='Composer', genre='Genre', year='2026', lossless=1") }
        let tracks = try await manager.dbQueue.read { try Track.select(Track.lightweightSelection).fetchAll($0) }
        try FileManager.default.removeItem(at: original)
        try FileManager.default.removeItem(at: unrelatedPath)
        let removedCount = try await manager.cleanupAfterTrackRemoval(tracks)
        XCTAssertEqual(removedCount, 1)
        let protectedOnlyCount = try await manager.cleanupAfterTrackRemoval(tracks.filter { $0.trackId == trackID })
        XCTAssertEqual(protectedOnlyCount, 0)
        XCTAssertEqual(try nativeIDs(crate), [trackID])
        let retained = try await manager.dbQueue.read { try String.fetchOne($0, sql: "SELECT path FROM tracks WHERE id=?", arguments: [trackID]) }
        let deleted = try await manager.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE id=?", arguments: [unrelated]) }
        XCTAssertEqual(retained, original.path)
        XCTAssertEqual(deleted, 0)
        manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("test.db"))
        do { _ = try await materialize(crate, track: trackID); XCTFail("missing original proof accepted") } catch {}
        XCTAssertEqual(try nativeIDs(crate), [trackID])
    }
}

extension PublicationMappingTests {
    func testExactRemoteRefreshRestoresBlockedProofWithoutChangingMembershipOrWire() async throws {
        let crate = try sharedCrate([trackID])
        let record = try await publish(trackID)
        _ = try await materialize(crate, track: trackID)
        try editMetadata(crate)
        try manager.invalidateSyncMapping("id:verified")
        do { _ = try await materialize(crate, track: trackID); XCTFail("remote block ignored") } catch {}
        XCTAssertEqual(try nativeIDs(crate), [trackID])
        XCTAssertEqual(try manager.syncStates().first { $0.localID == crate.id }?.members.first?.fileId, "id:verified")
        try await refresh(record)
        let done = try await materialize(crate, track: trackID)
        XCTAssertTrue(done)
        XCTAssertEqual(try nativeIDs(crate), [trackID])
    }
}

// Reproduce the coordinator's materialize -> remote-refresh -> outbox sequence.
extension PublicationMappingTests {
    func testChangedRemoteBlocksNewAndQueuedPublicationRevisions() async throws {
        let record = try await publish(trackID)
        let crate = try sharedCrate([trackID])
        let proof = try XCTUnwrap(record.verifiedMapping)
        // Remote bytes changed since publication; original and paired local copy did not.
        PublicationMappingProtocol.body = try JSONSerialization.data(withJSONObject: [
            ".tag": "file", "id": proof.fileID, "path_display": "/music/\(record.destination)",
            "content_hash": String(repeating: "0", count: 64), "size": proof.size
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicationMappingProtocol.self]
        let client = DropboxPlaylistTransport(accessToken: "fixture", session: URLSession(configuration: configuration))
        defer { client.session.invalidateAndCancel() }
        let pairing = try XCTUnwrap(manager.syncPairing())
        do {
            try await DropboxPlaylistSyncCoordinator.verifyPublicationReferences([proof.fileID], root: root, pairing: pairing, client: client, db: manager, scope: TemporaryScope())
            XCTFail("changed remote accepted before materialization")
        } catch PlaylistSyncError.mappingBlocked {}
        do { _ = try await materialize(crate, track: trackID); XCTFail("blocked intent materialized") }
        catch PlaylistSyncError.mappingBlocked {}
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
        try await refresh(record)
        let done = try await materialize(crate, track: trackID)
        XCTAssertTrue(done)
        let queued = try manager.syncOutbox().map { $0.1 }
        PublicationMappingProtocol.body = try JSONSerialization.data(withJSONObject: [
            ".tag": "file", "id": proof.fileID, "path_display": "/music/\(record.destination)",
            "content_hash": String(repeating: "0", count: 64), "size": proof.size
        ])
        let mapped = try await DropboxPlaylistSyncCoordinator.refreshRemoteMapping(proof.fileID,
            root: root, pairing: pairing, client: client, db: manager, scope: TemporaryScope())
        XCTAssertFalse(mapped)
        let blocked = try await manager.dbQueue.read { try Data.fetchOne($0, sql: "SELECT value FROM playlist_sync_meta WHERE key=?", arguments: ["publication-blocked:\(record.id.uuidString)"]) }
        XCTAssertNotNil(blocked)
        do {
            try await DropboxPlaylistSyncCoordinator.verifyPublicationReferences([proof.fileID], root: root, pairing: pairing, client: client, db: manager, scope: TemporaryScope())
            XCTFail("changed remote accepted before upload")
        } catch PlaylistSyncError.mappingBlocked {}
        XCTAssertEqual(try manager.syncOutbox().map { $0.1 }, queued)
        try await refresh(record)
        try await DropboxPlaylistSyncCoordinator.verifyPublicationReferences([proof.fileID], root: root, pairing: pairing, client: client, db: manager, scope: TemporaryScope())
        XCTAssertEqual(try manager.syncOutbox().map { $0.1 }, queued)
    }
}
