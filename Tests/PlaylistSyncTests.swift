import Foundation
import GRDB
import XCTest
import Security
@testable import Petrichor

final class PlaylistSyncTests: XCTestCase {
    private var directory: URL!
    private var manager: DatabaseManager!
    private var fixtureFolderID: Int64!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("sync.db"))
        fixtureFolderID = try manager.dbQueue.write { db in
            var folder = Folder(url: directory)
            try folder.insert(db)
            folder.id = db.lastInsertedRowID
            return folder.id!
        }
    }
    override func tearDownWithError() throws {
        manager = nil
        try FileManager.default.removeItem(at: directory)
    }
    func testRenameIntentSurvivesReopenAndRollback() async throws {
        var playlist = Playlist(name: "Original")
        try await manager.savePlaylistAsync(playlist)
        try manager.sharePlaylist(playlist.id)
        playlist.name = "Updated"
        try await manager.updatePlaylistMetadata(playlist)
        let captured = try XCTUnwrap(manager.syncIntent(playlist.id))
        XCTAssertEqual(captured.name, "Updated")
        manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("sync.db"))
        XCTAssertEqual(try manager.syncIntent(playlist.id), captured)
        enum Rollback: Error { case forced }
        let rollback: () throws -> Void = { try self.manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE playlists SET name = 'Rollback' WHERE id = ?", arguments: [playlist.id.uuidString])
            try self.manager.capturePlaylistIntent(db, playlistID: playlist.id, mutation: .metadata)
            throw Rollback.forced
        } }
        XCTAssertThrowsError(try rollback())
        XCTAssertEqual(try manager.syncIntent(playlist.id), captured)
        XCTAssertEqual(manager.loadAllPlaylists().first { $0.id == playlist.id }?.name, "Updated")
    }
    func testDeleteCapturesTombstoneWithoutDeletingAudio() async throws {
        let audio = directory.appendingPathComponent("keep.wav")
        try Data("audio fixture".utf8).write(to: audio)
        let trackID = try addFixtureTrack("keep.wav")
        let playlist = Playlist(name: "Delete", tracks: manager.getTracksWithArtwork(byIds: [trackID]))
        try await manager.savePlaylistAsync(playlist)
        try manager.sharePlaylist(playlist.id)
        try await manager.deletePlaylist(playlist.id)
        XCTAssertTrue(try XCTUnwrap(manager.syncIntent(playlist.id)).deleted)
        XCTAssertFalse(manager.loadAllPlaylists().contains { $0.id == playlist.id })
        XCTAssertEqual(manager.loadAllPlaylists().filter { !$0.isUserEditable }.count, 3)
        let remaining = try await manager.dbQueue.read { try Track.fetchOne($0, key: trackID) }
        XCTAssertNotNil(remaining)
        XCTAssertEqual(try Data(contentsOf: audio), Data("audio fixture".utf8))
    }
    func testProtocolRejectsDuplicateAndInvalidVersion() throws {
        let revision = PlaylistRevision(protocolVersion: 1, libraryId: UUID().uuidString.lowercased(),
            playlistId: UUID().uuidString.lowercased(), revisionId: UUID().uuidString.lowercased(),
            parentRevisionIds: [], deviceId: UUID().uuidString.lowercased(), name: "Warmup", deleted: false,
            tracks: [DropboxTrackReference(fileId: "id:a")])
        let bytes = try JSONEncoder().encode(revision)
        XCTAssertEqual(try PlaylistRevision.decode(bytes), revision)
        var duplicate = revision
        duplicate.tracks.append(duplicate.tracks[0])
        XCTAssertThrowsError(try duplicate.validate())
        duplicate = revision
        duplicate.protocolVersion = 2
        XCTAssertThrowsError(try duplicate.validate())
    }
    func testChildBeforeParentAndConflictHeads() throws {
        let root = revision(parents: [])
        let child = revision(parents: [root.revisionId], playlist: root.playlistId, library: root.libraryId)
        XCTAssertTrue(try RevisionGraph(revisions: [child]).incomplete)
        XCTAssertEqual(try RevisionGraph(revisions: [child, root]).heads, [child.revisionId])
        let sibling = revision(parents: [root.revisionId], playlist: root.playlistId, library: root.libraryId)
        XCTAssertEqual(Set(try RevisionGraph(revisions: [root, child, sibling]).heads), Set([child.revisionId, sibling.revisionId]))
    }
    func testUnresolvedSlotsAndAliasesSurviveReorder() {
        let members = [SyncMember(fileId: "id:a", localTrackID: 1), SyncMember(fileId: "id:missing", localTrackID: nil),
            SyncMember(fileId: "id:alias", localTrackID: 1), SyncMember(fileId: "id:b", localTrackID: 2)]
        let reordered = SyncMember.projectEdit(members, orderedIDs: [2, 1], removedIDs: [])
        let adjacentAliases = [members[0], members[2], members[1], members[3]]
        XCTAssertEqual(SyncMember.projectEdit(adjacentAliases, orderedIDs: [2, 1], removedIDs: []).compactMap(\.fileId), ["id:b", "id:missing", "id:a", "id:alias"])
        XCTAssertEqual(reordered.compactMap(\.fileId), ["id:b", "id:missing", "id:a", "id:alias"])
        XCTAssertEqual(SyncMember.projectEdit(members, orderedIDs: [2], removedIDs: [1]).compactMap(\.fileId), ["id:missing", "id:b"])
    }
    func testStaleEditorFailsAtomically() async throws {
        var playlist = Playlist(name: "Before")
        try await manager.savePlaylistAsync(playlist)
        try manager.sharePlaylist(playlist.id)
        let snapshot = try manager.playlistEditorSnapshot(playlist.id)
        playlist.name = "Remote or newer"
        try await manager.updatePlaylistMetadata(playlist)
        do {
            try await manager.savePlaylistEditor(playlistID: playlist.id, name: "Stale", tracks: [], expected: snapshot)
            XCTFail("Expected stale editor error")
        } catch PlaylistSyncError.staleEditor { }
        XCTAssertEqual(manager.loadAllPlaylists().first { $0.id == playlist.id }?.name, "Remote or newer")
    }
    private func revision(parents: [String], playlist: String? = nil, library: String? = nil) -> PlaylistRevision {
        PlaylistRevision(protocolVersion: 1, libraryId: library ?? UUID().uuidString.lowercased(),
            playlistId: playlist ?? UUID().uuidString.lowercased(), revisionId: UUID().uuidString.lowercased(),
            parentRevisionIds: parents.sorted(), deviceId: UUID().uuidString.lowercased(), name: "Test", deleted: false, tracks: [])
    }
}

extension PlaylistSyncTests {
    func testSharedWireFixtures() throws {
        struct RevisionCase: Decodable { var name: String; var valid: Bool; var revision: FixtureJSON }
        struct DescriptorCase: Decodable { var name: String; var valid: Bool; var descriptor: FixtureJSON }
        struct GraphCase: Decodable { var name: String; var revisions: [String]; var state: String; var headIds: [String] }
        struct Fixtures: Decodable {
            var revisions: [String: PlaylistRevision]
            var validationCases: [RevisionCase]
            var descriptorCases: [DescriptorCase]
            var graphCases: [GraphCase]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // An isolated sandboxed test host may not have Desktop access. CI can supply
        // a byte-identical fixture copy without granting access to the user's folders.
        let fixtureURL = ProcessInfo.processInfo.environment["CRATE_SYNC_FIXTURE_PATH"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("docs/fixtures/dropbox-playlist-protocol.json")
        let fixture = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixtureURL))
        for item in fixture.validationCases {
            let data = try JSONEncoder().encode(item.revision)
            if item.valid { XCTAssertNoThrow(try PlaylistRevision.decode(data), item.name) }
            else { XCTAssertThrowsError(try PlaylistRevision.decode(data), item.name) }
        }
        for item in fixture.graphCases {
            let values = try item.revisions.map { try XCTUnwrap(fixture.revisions[$0]) }
            if item.state == "error" { XCTAssertThrowsError(try RevisionGraph(revisions: values)); continue }
            let graph = try RevisionGraph(revisions: values)
            XCTAssertEqual(graph.heads, item.headIds, item.name)
            XCTAssertEqual(graph.incomplete, item.state == "pending")
        }
        for item in fixture.descriptorCases {
            let data = try JSONEncoder().encode(item.descriptor)
            if item.valid { XCTAssertNoThrow(try JSONDecoder().decode(SyncLibraryDescriptor.self, from: data).validate(), item.name) }
            else { XCTAssertThrowsError(try JSONDecoder().decode(SyncLibraryDescriptor.self, from: data).validate(), item.name) }
        }
    }
    func testBlockedIntentKeepsRemoteFromReplacingLocalAndGenerationCheckedMaterialization() async throws {
        let playlist = Playlist(name: "Local draft")
        try await manager.savePlaylistAsync(playlist)
        try manager.sharePlaylist(playlist.id)
        let state = try XCTUnwrap(manager.syncStates().first)
        let pairing = SyncPairing(descriptor: SyncLibraryDescriptor(libraryId: UUID().uuidString.lowercased(), accountId: "dbid:test", namespaceId: "test", musicFolderId: "id:music"), localRootBookmark: Data(), localRootPath: "/fixture", remoteRootPath: "/Music")
        try manager.saveSyncPairing(pairing)
        var remote = revision(parents: [], playlist: state.sharedID, library: pairing.descriptor.libraryId)
        remote.name = "Remote draft"
        try manager.receiveSyncRevision(JSONEncoder().encode(remote), path: remote.path, library: remote.libraryId)
        try manager.projectSyncRevisions()
        XCTAssertEqual(manager.loadAllPlaylists().first { $0.id == playlist.id }?.name, "Local draft")
        XCTAssertNotNil(try manager.syncIntent(playlist.id))
        XCTAssertFalse(try manager.materializeSyncIntent(playlist.id, generation: state.generation - 1, resolved: [:]))
        XCTAssertTrue(try manager.materializeSyncIntent(playlist.id, generation: state.generation, resolved: [:]))
        try manager.projectSyncRevisions()
        XCTAssertEqual(try manager.syncStates().first?.issue, "conflict")
        XCTAssertEqual(manager.loadAllPlaylists().first { $0.id == playlist.id }?.name, "Local draft")
    }
    func testMoreThan32HeadsResolveInAtomicParentFirstChain() throws {
        let library = UUID().uuidString.lowercased(), shared = UUID().uuidString.lowercased()
        let versions = (0..<70).map { _ in revision(parents: [], playlist: shared, library: library) }
        for item in versions { try manager.receiveSyncRevision(JSONEncoder().encode(item), path: item.path, library: library) }
        try manager.projectSyncRevisions()
        let state = try XCTUnwrap(manager.syncStates().first)
        XCTAssertEqual(state.heads.count, 70)
        try manager.resolveSyncConflict(localID: state.localID, chosen: versions[0].revisionId, expectedHeads: state.heads)
        let queued = try manager.syncOutbox().map { try PlaylistRevision.decode($0.1) }
        XCTAssertEqual(queued.count, 3)
        XCTAssertEqual(queued[0].parentRevisionIds.count, 32)
        XCTAssertTrue(queued[1].parentRevisionIds.contains(queued[0].revisionId))
        XCTAssertTrue(queued[2].parentRevisionIds.contains(queued[1].revisionId))
        XCTAssertEqual(try RevisionGraph(revisions: manager.syncRevisions(shared)).heads, [queued.last!.revisionId])
        XCTAssertEqual(manager.loadAllPlaylists().filter { $0.type == .regular && $0.isUserEditable }.count, 1)
    }
    func testDiscoveryCursorObligationsAndExactBodyReplay() throws {
        let item = revision(parents: [])
        let body = try JSONEncoder().encode(item)
        try manager.saveSyncDiscovery(paths: [item.path], cursor: "durable-cursor")
        manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("sync.db"))
        XCTAssertEqual(try manager.syncCursor(), "durable-cursor")
        XCTAssertEqual(try manager.syncIncomingPaths(), [item.path])
        try manager.receiveSyncRevision(body, path: item.path, library: item.libraryId)
        try manager.receiveSyncRevision(body, path: item.path, library: item.libraryId)
        XCTAssertTrue(try manager.syncIncomingPaths().isEmpty)
        var different = item; different.name = "Collision"
        XCTAssertThrowsError(try manager.receiveSyncRevision(JSONEncoder().encode(different), path: item.path, library: item.libraryId))
        try manager.projectSyncRevisions()
        try manager.projectSyncRevisions()
        XCTAssertEqual(manager.loadAllPlaylists().filter { $0.type == .regular && $0.isUserEditable }.count, 1)
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
    }
    func testReceivedMissingAliasRetainedAcrossRenameAndNewMappingStalesEditor() async throws {
        let trackID = try addFixtureTrack("a.wav")
        var item = revision(parents: [])
        item.tracks = [DropboxTrackReference(fileId: "id:a"), DropboxTrackReference(fileId: "id:missing"), DropboxTrackReference(fileId: "id:alias")]
        try manager.saveSyncMapping(fileID: "id:a", trackID: trackID, hash: "verified")
        try manager.saveSyncMapping(fileID: "id:alias", trackID: trackID, hash: "verified")
        try manager.receiveSyncRevision(JSONEncoder().encode(item), path: item.path, library: item.libraryId)
        try manager.projectSyncRevisions()
        let state = try XCTUnwrap(manager.syncStates().first)
        XCTAssertEqual(manager.loadTracksForPlaylist(state.localID).count, 1)
        let snapshot = try manager.playlistEditorSnapshot(state.localID)
        let second = try addFixtureTrack("b.wav")
        try manager.saveSyncMapping(fileID: "id:missing", trackID: second, hash: "verified")
        do {
            try await manager.savePlaylistEditor(playlistID: state.localID, name: "Stale", tracks: [], expected: snapshot)
            XCTFail("Expected mapping snapshot guard")
        } catch PlaylistSyncError.staleEditor { }
        try manager.projectSyncRevisions()
        XCTAssertEqual(manager.loadTracksForPlaylist(state.localID).count, 2)
        var playlist = try XCTUnwrap(manager.loadAllPlaylists().first { $0.id == state.localID })
        playlist.name = "Renamed"
        try await manager.updatePlaylistMetadata(playlist)
        let intent = try XCTUnwrap(manager.syncIntent(state.localID))
        XCTAssertEqual(intent.members.compactMap(\.fileId), ["id:a", "id:missing", "id:alias"])
    }
    private func addFixtureTrack(_ name: String) throws -> Int64 {
        try manager.dbQueue.write { db in
            let url = directory.appendingPathComponent(name)
            try db.execute(sql: "INSERT INTO tracks (folder_id, path, filename, title, artist, album, composer, genre, year, duration, format, date_added, is_duplicate) VALUES (?, ?, ?, ?, 'Artist', 'Album', 'Composer', 'Genre', '2026', 0.1, 'wav', ?, 0)", arguments: [fixtureFolderID, url.path, name, name, Date()])
            return db.lastInsertedRowID
        }
    }
}

private enum FixtureJSON: Codable {
    case object([String: FixtureJSON]), array([FixtureJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([FixtureJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: FixtureJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension PlaylistSyncTests {
    func testAtomicEditorNewTrackAtFrontPreservesWireOrderAndUnresolvedSlot() async throws {
        let a = try addFixtureTrack("a.wav"), b = try addFixtureTrack("b.wav"), c = try addFixtureTrack("c.wav")
        var item = revision(parents: [])
        item.tracks = [DropboxTrackReference(fileId: "id:a"), DropboxTrackReference(fileId: "id:unresolved"), DropboxTrackReference(fileId: "id:b")]
        try manager.saveSyncMapping(fileID: "id:a", trackID: a, hash: "verified")
        try manager.saveSyncMapping(fileID: "id:b", trackID: b, hash: "verified")
        try manager.receiveSyncRevision(JSONEncoder().encode(item), path: item.path, library: item.libraryId)
        try manager.projectSyncRevisions()
        let state = try XCTUnwrap(manager.syncStates().first)
        let snapshot = try manager.playlistEditorSnapshot(state.localID)
        let byID = Dictionary(manager.getTracksWithArtwork(byIds: [a, b, c]).map { ($0.trackId!, $0) }, uniquingKeysWith: { first, _ in first })
        try await manager.savePlaylistEditor(playlistID: state.localID, name: "At front", tracks: [c, a, b].compactMap { byID[$0] }, expected: snapshot)
        var intent = try XCTUnwrap(manager.syncIntent(state.localID))
        XCTAssertEqual(intent.members.map { $0.fileId ?? "local:\($0.localTrackID!)" }, ["local:\(c)", "id:unresolved", "id:a", "id:b"])
        XCTAssertEqual(intent.members.first?.localPath, directory.appendingPathComponent("c.wav").path)
        // A second edit before publication retains the original pinned parent baseline.
        let secondSnapshot = try manager.playlistEditorSnapshot(state.localID)
        try await manager.savePlaylistEditor(playlistID: state.localID, name: "At middle", tracks: [a, c, b].compactMap { byID[$0] }, expected: secondSnapshot)
        intent = try XCTUnwrap(manager.syncIntent(state.localID))
        XCTAssertEqual(intent.members.map { $0.fileId ?? "local:\($0.localTrackID!)" }, ["id:a", "id:unresolved", "local:\(c)", "id:b"])
        XCTAssertEqual(intent.parents, [item.revisionId])
    }
    func testSourceMaintenanceDoesNotCaptureMembershipDeletion() async throws {
        let a = try addFixtureTrack("source.wav")
        var playlist = Playlist(name: "Source retained", tracks: manager.getTracksWithArtwork(byIds: [a]))
        try await manager.savePlaylistAsync(playlist)
        try manager.sharePlaylist(playlist.id)
        let original = try XCTUnwrap(manager.syncIntent(playlist.id))
        try await manager.dbQueue.write { db in try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == playlist.id.uuidString).deleteAll(db) }
        playlist.name = "Renamed after source maintenance"
        try await manager.updatePlaylistMetadata(playlist)
        XCTAssertEqual(try manager.syncIntent(playlist.id)?.members, original.members)
    }
}

extension PlaylistSyncTests {
    func testUnmappedOriginNeverMaterializesAShortenedPlaylist() async throws {
        let a = try addFixtureTrack("origin-a.wav"), b = try addFixtureTrack("origin-b.wav")
        let byID = Dictionary(manager.getTracksWithArtwork(byIds: [a, b]).map { ($0.trackId!, $0) }, uniquingKeysWith: { first, _ in first })
        let playlist = Playlist(name: "Complete only", tracks: [a, b].compactMap { byID[$0] })
        try await manager.savePlaylistAsync(playlist)
        try manager.sharePlaylist(playlist.id)
        let intent = try XCTUnwrap(manager.syncIntent(playlist.id))
        let descriptor = SyncLibraryDescriptor(libraryId: UUID().uuidString.lowercased(), accountId: "dbid:test", namespaceId: "test", musicFolderId: "id:music")
        try manager.saveSyncPairing(SyncPairing(descriptor: descriptor, localRootBookmark: Data(), localRootPath: directory.path, remoteRootPath: "/Music"))
        XCTAssertThrowsError(try manager.materializeSyncIntent(playlist.id, generation: intent.generation, resolved: [a: "id:a"]))
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
        XCTAssertEqual(try manager.syncIntent(playlist.id), intent)
        XCTAssertTrue(try manager.materializeSyncIntent(playlist.id, generation: intent.generation, resolved: [a: "id:a", b: "id:b"]))
        let body = try XCTUnwrap(manager.syncOutbox().first?.1)
        XCTAssertEqual(try PlaylistRevision.decode(body).tracks.map(\.fileId), ["id:a", "id:b"])
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains(directory.path))
        manager = try DatabaseManager(databaseURL: directory.appendingPathComponent("sync.db"))
        XCTAssertEqual(try manager.syncOutbox().first?.1, body)
        XCTAssertNil(try manager.syncIntent(playlist.id))
    }
}

extension PlaylistSyncTests {
    func testVerifiedMappingRejectsSameIDPathRelocationAtomically() async throws {
        let id = try addFixtureTrack("verified.wav")
        let originalPath = directory.appendingPathComponent("verified.wav").path
        try Data("verified audio".utf8).write(to: URL(fileURLWithPath: originalPath))
        let hash = try DropboxPlaylistTransport.contentHash(URL(fileURLWithPath: originalPath))
        try manager.saveSyncMapping(fileID: "id:verified", trackID: id, hash: hash, expectedPath: originalPath)
        let playlist = Playlist(name: "Captured origin", tracks: manager.getTracksWithArtwork(byIds: [id]))
        try await manager.savePlaylistAsync(playlist)
        try manager.sharePlaylist(playlist.id)
        let captured = try XCTUnwrap(manager.syncIntent(playlist.id))
        // Simulate the real folder relocation seam after async content verification.
        let movedPath = directory.appendingPathComponent("moved.wav").path
        try await manager.dbQueue.write { db in try db.execute(sql: "UPDATE tracks SET path = ? WHERE id = ?", arguments: [movedPath, id]) }
        XCTAssertThrowsError(try manager.saveSyncMapping(fileID: "id:verified", trackID: id, hash: "replacement", expectedPath: originalPath))
        let stored = try await manager.dbQueue.read { try String.fetchOne($0, sql: "SELECT content_hash FROM playlist_sync_mapping WHERE file_id = 'id:verified'") }
        XCTAssertEqual(stored, hash)
        XCTAssertEqual(try manager.syncIntent(playlist.id), captured)
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
        XCTAssertEqual(captured.members.first?.localPath, originalPath)
    }
}

extension PlaylistSyncTests {
    func testInvalidNewGraphIsSurfacedWhileUnrelatedPlaylistProjects() throws {
        let library = UUID().uuidString.lowercased(), shared = UUID().uuidString.lowercased()
        var a = revision(parents: [], playlist: shared, library: library)
        let b = revision(parents: [a.revisionId], playlist: shared, library: library)
        a.parentRevisionIds = [b.revisionId]
        var healthy = revision(parents: [], library: library)
        healthy.name = "Healthy unrelated playlist"
        for item in [a, b, healthy] {
            try manager.receiveSyncRevision(JSONEncoder().encode(item), path: item.path, library: library)
        }
        try manager.projectSyncRevisions()
        let invalid = try XCTUnwrap(manager.syncStates().first { $0.sharedID == shared })
        XCTAssertEqual(invalid.issue, "invalid")
        XCTAssertFalse(manager.loadAllPlaylists().contains { $0.id == invalid.localID })
        let good = try XCTUnwrap(manager.syncStates().first { $0.sharedID == healthy.playlistId })
        XCTAssertEqual(manager.loadAllPlaylists().first { $0.id == good.localID }?.name, healthy.name)
        XCTAssertEqual(try manager.syncRevisions(shared).count, 2)
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
    }
}


extension PlaylistSyncTests {
    func testMetadataSyncedAndUnavailableAudioAreIndependent() {
        let state = SyncPlaylistState(localID: UUID(), sharedID: UUID().uuidString, generation: 1,
            heads: ["head"], members: [SyncMember(fileId: "id:missing", localTrackID: nil)],
            intent: nil, appliedHead: "head", issue: nil)
        XCTAssertEqual(CrateSyncPresentation.summary(state: state, connected: true, working: false, queued: false), "Crate synced")
        XCTAssertEqual(CrateSyncPresentation.unavailable(state), 1)
        XCTAssertEqual(CrateSyncPresentation.summary(state: state, connected: true, working: false, queued: true), "Changes waiting to sync")
    }
    func testPendingIntentAndConflictTakePrecedenceOverSynced() {
        var state = SyncPlaylistState(localID: UUID(), sharedID: UUID().uuidString, generation: 1,
            heads: [], members: [], intent: SyncIntent(generation: 1, name: "Draft", deleted: false,
                members: [SyncMember(fileId: nil, localTrackID: 42)], parents: []), appliedHead: nil, issue: "mapping")
        XCTAssertEqual(CrateSyncPresentation.summary(state: state, connected: true, working: false, queued: false), "Changes waiting to sync")
        XCTAssertEqual(CrateSyncPresentation.needsAdding(state), 1)
        state.issue = "conflict"
        XCTAssertEqual(CrateSyncPresentation.summary(state: state, connected: true, working: false, queued: false), "Changes on both devices")
        XCTAssertEqual(CrateSyncPresentation.summary(state: state, connected: false, working: false, queued: false), "Reconnect Dropbox")
        XCTAssertEqual(CrateSyncPresentation.summary(state: nil, connected: false, working: false, queued: false), "Connect Dropbox to share this crate")
    }
    func testConflictChoiceRejectsStaleHeadsWithoutWrites() throws {
        let first = revision(parents: [])
        let second = revision(parents: [], playlist: first.playlistId, library: first.libraryId)
        for item in [first, second] { try manager.receiveSyncRevision(JSONEncoder().encode(item), path: item.path, library: item.libraryId) }
        try manager.projectSyncRevisions()
        let state = try XCTUnwrap(manager.syncStates().first)
        let third = revision(parents: [second.revisionId], playlist: first.playlistId, library: first.libraryId)
        try manager.receiveSyncRevision(JSONEncoder().encode(third), path: third.path, library: third.libraryId)
        XCTAssertThrowsError(try manager.resolveSyncConflict(localID: state.localID, chosen: first.revisionId, expectedHeads: state.heads))
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
        XCTAssertEqual(try manager.syncRevisions(first.playlistId).count, 3)
    }
}

extension PlaylistSyncTests {
    func testKeepBothRejectsSameOrNonHeadCopyAtomically() throws {
        let ancestor = revision(parents: [])
        let first = revision(parents: [ancestor.revisionId], playlist: ancestor.playlistId, library: ancestor.libraryId)
        let second = revision(parents: [ancestor.revisionId], playlist: ancestor.playlistId, library: ancestor.libraryId)
        for item in [ancestor, first, second] { try manager.receiveSyncRevision(JSONEncoder().encode(item), path: item.path, library: item.libraryId) }
        try manager.projectSyncRevisions()
        let state = try XCTUnwrap(manager.syncStates().first)
        XCTAssertThrowsError(try manager.resolveSyncConflict(localID: state.localID, chosen: first.revisionId,
            expectedHeads: state.heads, keepBoth: ancestor.revisionId))
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
        XCTAssertThrowsError(try manager.resolveSyncConflict(localID: state.localID, chosen: first.revisionId,
            expectedHeads: state.heads, keepBoth: first.revisionId))
        XCTAssertTrue(try manager.syncOutbox().isEmpty)
    }
}

extension PlaylistSyncTests {
    func testDeleteVersusEditKeepBothRetainsLiveCopyAndTombstone() throws {
        var removed = revision(parents: [])
        removed.deleted = true
        var edited = revision(parents: [], playlist: removed.playlistId, library: removed.libraryId)
        edited.name = "Surviving edit"
        edited.tracks = [DropboxTrackReference(fileId: "id:unavailable")]
        for item in [removed, edited] { try manager.receiveSyncRevision(JSONEncoder().encode(item), path: item.path, library: item.libraryId) }
        try manager.projectSyncRevisions()
        let state = try XCTUnwrap(manager.syncStates().first)
        try manager.resolveSyncConflict(localID: state.localID, chosen: removed.revisionId, expectedHeads: state.heads, keepBoth: edited.revisionId)
        let queued = try manager.syncOutbox().map { try PlaylistRevision.decode($0.1) }
        XCTAssertEqual(queued.count, 2)
        XCTAssertTrue(try XCTUnwrap(queued.first { $0.playlistId == removed.playlistId }).deleted)
        let copy = try XCTUnwrap(queued.first { $0.playlistId != removed.playlistId })
        XCTAssertEqual(copy.tracks, edited.tracks)
        XCTAssertEqual(copy.name, "Surviving edit (conflict copy)")
    }
}

extension PlaylistSyncTests {
    func testPresentationCredentialCheckNeverReadsDataOrAllowsAuthenticationUI() {
        var checks = 0
        XCTAssertTrue(DropboxSyncVault.hasSavedCredentials { query in
            checks += 1
            let attributes = query as! [String: Any]
            XCTAssertNil(attributes[kSecReturnData as String])
            XCTAssertEqual(attributes[kSecReturnAttributes as String] as? Bool, true)
            XCTAssertEqual(attributes[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
            return errSecInteractionNotAllowed
        })
        XCTAssertEqual(checks, 1)
        XCTAssertFalse(DropboxSyncVault.hasSavedCredentials { _ in errSecItemNotFound })
    }
}
