import Foundation
import GRDB
import XCTest
@testable import Petrichor

final class PublicationServiceTests: XCTestCase {
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
    actor Fake: PublicationTransport {
        var remote: PublicationRemoteProof?
        var expected: PublicationRemoteProof
        var starts = 0
        var finishes = 0
        var offsets: [UInt64] = []
        var sizes: [Int] = []
        var failAppend: PublicationError?
        var failureOffset: UInt64 = 0
        var metadataFailureAfterFinish = false
        var metadataError: PublicationError?
        var cancelTaskOnFinish = false
        var commitOnFinish = true
        var finishFailure: PublicationError?
        var active = 0
        var peak = 0
        var lostFinish = false
        var cancelOnFinish: (() async throws -> Void)?
        var duringAppend: (() async throws -> Void)?
        init(_ record: Publication) {
            expected = PublicationRemoteProof(fileID: "id:verified", contentHash: record.snapshot.dropboxHash!, size: UInt64(record.snapshot.sourceIdentity!.size))
        }
        func metadataAtDestination() async throws -> PublicationRemoteProof? {
            if Task.isCancelled { throw CancellationError() }
            if let metadataError { self.metadataError = nil; throw metadataError }
            if metadataFailureAfterFinish && finishes > 0 { metadataFailureAfterFinish = false; throw PublicationError.retryable }
            return remote
        }
        func start() async throws -> String { starts += 1; active += 1; peak = max(peak, active); return "session-\(starts)" }
        func append(session: String, offset: UInt64, bytes: Data) async throws -> UInt64 {
            offsets.append(offset); sizes.append(bytes.count)
            try await Task.sleep(nanoseconds: 5_000_000)
            if let error = failAppend, offset == failureOffset { failAppend = nil; throw error }
            try await duringAppend?()
            return offset + UInt64(bytes.count)
        }
        func finish(session: String, offset: UInt64) async throws {
            finishes += 1
            active -= 1
            if commitOnFinish { remote = expected }
            try await cancelOnFinish?()
            if cancelTaskOnFinish { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
            if let finishFailure { throw finishFailure }
            if lostFinish { throw PublicationError.retryable }
        }
        func setFailure(_ error: PublicationError, offset: UInt64 = 0) { failAppend = error; failureOffset = offset }
        func setFinishFailure(_ error: PublicationError) { finishFailure = error; commitOnFinish = false }
        func setTaskCancellation(commit: Bool) { cancelTaskOnFinish = true; commitOnFinish = commit }
        func setMetadataError(_ error: PublicationError) { metadataError = error }
        func setMetadataFailure() { metadataFailureAfterFinish = true }
        func peakCount() -> Int { peak }
        func setLostFinish() { lostFinish = true }
        func setRemote(_ proof: PublicationRemoteProof) { remote = proof }
        func setAppend(_ callback: @escaping () async throws -> Void) { duringAppend = callback }
        func setCancel(_ callback: @escaping () async throws -> Void) { cancelOnFinish = callback }
        func counts() -> (Int, Int, [UInt64], [Int]) { (starts, finishes, offsets, sizes) }
    }
    func captured() async throws -> Publication {
        let id = try await service.capture(trackID: trackID, destinationRelativePath: "copy.wav", confirmedOutsideRootCopy: true)
        return try XCTUnwrap(service.journal.record(id))
    }
    func testLostFinishResponseAndRetryUseOneVerifiedRemoteID() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        await fake.setLostFinish()
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        await upload.run(id: record.id)
        let result = try XCTUnwrap(service.journal.record(record.id))
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.verifiedMapping?.fileID, "id:verified")
        let counts = await fake.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }
    func testDifferentDestinationBytesRequireNewNameWithoutStarting() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        await fake.setRemote(PublicationRemoteProof(fileID: "id:other", contentHash: String(repeating: "0", count: 64), size: 1))
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.error, .needsNewName)
        let counts = await fake.counts(); XCTAssertEqual(counts.0, 0)
    }
    func testExpiredSessionRestartsAndTransientRetryRetainsOffset() async throws {
        // More than one chunk proves offsets are durable and memory reads stay bounded.
        try Data(repeating: 42, count: 17 * 1024 * 1024 + 7).write(to: original)
        let record = try await captured(), fake = Fake(try await captured())
        await fake.setFailure(.sessionExpired)
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.state, .completed)
        let counts = await fake.counts()
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.2, [UInt64(0), 0, UInt64(8 * 1024 * 1024), UInt64(16 * 1024 * 1024)])
        XCTAssertLessThanOrEqual(counts.3.max()!, 8 * 1024 * 1024)
    }
    func testProviderFailuresRemainSanitizedAndRetryableItemResumes() async throws {
        for error: PublicationError in [.quota, .auth, .root, .retryable] {
            let record = try await captured(), fake = Fake(try await captured())
            await fake.setFailure(error)
            let upload = PublicationService(source: service) { _ in fake }
            await upload.run(id: record.id)
            XCTAssertEqual(try service.journal.record(record.id)?.error, error)
            await upload.run(id: record.id)
            XCTAssertEqual(try service.journal.record(record.id)?.state, .completed)
            let counts = await fake.counts(); XCTAssertEqual(counts.0, 1)
        }
    }
    func testCancelBeforeStartAndAfterCommittedFinish() async throws {
        let before = try await captured(), fake = Fake(try await captured())
        let upload = PublicationService(source: service) { _ in fake }
        try await upload.cancel(id: before.id)
        await upload.run(id: before.id)
        XCTAssertEqual(try service.journal.record(before.id)?.state, .cancelled)
        let record = try await captured()
        await fake.setCancel { try await upload.cancel(id: record.id) }
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.state, .completed)
        XCTAssertEqual(try service.journal.record(before.id)?.state, .cancelled)
    }
    func testStaleGenerationCannotReplaceNewerOrCompletedState() async throws {
        let record = try await captured()
        let first = try XCTUnwrap(service.journal.claim(record.id))
        _ = try service.journal.claim(record.id)
        XCTAssertThrowsError(try service.journal.save(first))
        try service.journal.cancel(record.id)
        XCTAssertThrowsError(try service.journal.complete(first, proof: PublicationRemoteProof(fileID: "id:x", contentHash: record.snapshot.dropboxHash!, size: UInt64(record.snapshot.sourceIdentity!.size))))
    }
    func testSnapshotMutationFailsBeforeUpload() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.snapshot.snapshotPath!)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: record.snapshot.snapshotPath!))
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.state, .failed)
        let counts = await fake.counts(); XCTAssertEqual(counts.0, 0)
    }
    func testLostFinalMetadataRetryChecksDestinationBeforeStartingSession() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        await fake.setMetadataFailure()
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.state, .verifying)
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.state, .completed)
        let counts = await fake.counts(); XCTAssertEqual(counts.0, 1)
    }
    func testRetryResumesConfirmedSecondChunkAndKeepsOtherCompletion() async throws {
        try Data(repeating: 1, count: 17 * 1024 * 1024).write(to: original)
        let record = try await captured(), fake = Fake(try await captured())
        await fake.setFailure(.retryable, offset: UInt64(8 * 1024 * 1024))
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.uploadSession?.offset, UInt64(8 * 1024 * 1024))
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.state, .completed)
        let counts = await fake.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.2, [UInt64(0), UInt64(8 * 1024 * 1024), UInt64(8 * 1024 * 1024), UInt64(16 * 1024 * 1024)])
        await fake.setFailure(.quota)
        let other = try await captured()
        // Equal remote bytes reuse proof, preserving both independently completed rows.
        await upload.run(id: other.id)
        XCTAssertEqual(try service.journal.record(record.id)?.state, .completed)
    }

    func testQueueBoundsConcurrentItemsAndSingleFlightsSameID() async throws {
        let first = try await captured()
        let second = try await captured()
        let third = try await captured()
        let fourth = try await captured()
        let records = [first, second, third, fourth]
        let fake = Fake(records[0])
        let upload = PublicationService(source: service) { _ in fake }
        await withTaskGroup(of: Void.self) { group in
            for record in records { group.addTask { await upload.run(id: record.id) } }
            group.addTask { await upload.run(id: records[0].id) }
        }
        let peak = await fake.peakCount()
        XCTAssertEqual(peak, 2)
        for record in records { XCTAssertEqual(try service.journal.record(record.id)?.state, .completed) }
        let failed = try await captured()
        let failedTransport = Fake(failed)
        await failedTransport.setFailure(.quota)
        let another = PublicationService(source: service) { _ in failedTransport }
        await another.run(id: failed.id)
        XCTAssertEqual(try service.journal.record(failed.id)?.error, .quota)
        for record in records { XCTAssertEqual(try service.journal.record(record.id)?.state, .completed) }
    }

    func testCancelDuringAppendPersistsCancellationAndNeverFinishesOrRestarts() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        let upload = PublicationService(source: service) { _ in fake }
        await fake.setAppend { try await upload.cancel(id: record.id) }
        await upload.run(id: record.id)
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.state, .cancelled)
        let counts = await fake.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
    }
    @MainActor
    func testDisconnectWhileCredentialsPendingCannotAdoptNewEpoch() async throws {
        let record = try await captured()
        do {
            _ = try await DropboxPublicationTransport.verified(record: record, manager: manager,
                authentication: DropboxPlaylistAuthentication(), credentialProvider: {
                    await Task.yield()
                    PublicationConnectionEpoch.shared.invalidate()
                    return DropboxSyncCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture)
                })
            XCTFail("Invalidated credential must not reach account network")
        } catch { XCTAssertEqual(error as? PublicationError, .auth) }
    }

    func testFactoryAuthenticationAndRootFailuresKeepTheirRecoveryCategories() async throws {
        for (error, expected): (PlaylistSyncError, PublicationError) in [(.authentication, .auth), (.writePermission, .auth), (.pairingChanged, .root), (.configuration, .root)] {
            let record = try await captured()
            let upload = PublicationService(source: service) { _ in throw error }
            await upload.run(id: record.id)
            XCTAssertEqual(try service.journal.record(record.id)?.error, expected)
        }
    }

    func testSourceChangeAfterAppendPreventsFinalization() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        let path = original
        await fake.setAppend { try Data("changed".utf8).write(to: path) }
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.error, .sourceChanged)
        let counts = await fake.counts(); XCTAssertEqual(counts.1, 0)
    }
    func testWrongFinalHashNeverCompletes() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        await fake.setCancel {
            await fake.setRemote(PublicationRemoteProof(fileID: "id:wrong", contentHash: String(repeating: "a", count: 64), size: UInt64(record.snapshot.sourceIdentity!.size)))
        }
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        XCTAssertEqual(try service.journal.record(record.id)?.error, .contentMismatch)
        XCTAssertNil(try service.journal.record(record.id)?.verifiedMapping)
    }

    func testCancelledLostFinishHasReadOnlyOutcomeRecoveryWithNoSecondStart() async throws {
        for commit in [true, false] {
            let record = try await captured(), fake = Fake(try await captured())
            await fake.setTaskCancellation(commit: commit)
            let upload = PublicationService(source: service) { _ in fake }
            await Task { await upload.run(id: record.id) }.value
            XCTAssertEqual(try service.journal.record(record.id)?.state, .cancelled)
            XCTAssertEqual(try service.journal.record(record.id)?.error, .finishUncertain)
            try await upload.reconcileOutcome(id: record.id)
            XCTAssertEqual(try service.journal.record(record.id)?.state, commit ? .completed : .cancelled)
            XCTAssertEqual(try service.journal.record(record.id)?.error, commit ? nil : .cancelled)
            let counts = await fake.counts()
            XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        }
    }

    func testDefinitiveFinishRejectionAndAbsentDestinationPreserveTypedRecovery() async throws {
        for error: PublicationError in [.quota, .auth, .root] {
            let record = try await captured(), fake = Fake(try await captured())
            await fake.setFinishFailure(error)
            let upload = PublicationService(source: service) { _ in fake }
            await upload.run(id: record.id)
            XCTAssertEqual(try service.journal.record(record.id)?.state, .failed)
            XCTAssertEqual(try service.journal.record(record.id)?.error, error)
        }
    }

    func testSourceChangedAfterRemoteCommitBlocksMappingWithLocalProofCategory() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        let path = original
        await fake.setCancel { try Data("changed after finish".utf8).write(to: path) }
        let upload = PublicationService(source: service) { _ in fake }
        await upload.run(id: record.id)
        let result = try XCTUnwrap(service.journal.record(record.id))
        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.error, .sourceChanged)
        XCTAssertNil(result.verifiedMapping)
        let remote = try await fake.metadataAtDestination()
        XCTAssertEqual(remote?.fileID, "id:verified")
        let counts = await fake.counts(); XCTAssertEqual(counts.1, 1)
    }

    func testReadOnlyOutcomeKeepsLocalProofFailureDistinctFromUncertainFinish() async throws {
        let record = try await captured(), fake = Fake(try await captured())
        await fake.setTaskCancellation(commit: true)
        let upload = PublicationService(source: service) { _ in fake }
        await Task { await upload.run(id: record.id) }.value
        try Data("changed before outcome check".utf8).write(to: original)
        do { try await upload.reconcileOutcome(id: record.id); XCTFail() }
        catch { XCTAssertEqual(error as? PublicationError, .sourceChanged) }
        XCTAssertEqual(try service.journal.record(record.id)?.state, .cancelled)
        XCTAssertEqual(try service.journal.record(record.id)?.error, .sourceChanged)
        XCTAssertNil(try service.journal.record(record.id)?.verifiedMapping)
        let counts = await fake.counts(); XCTAssertEqual(counts.0, 1)
    }

    func testRetryLookupFailurePreservesUncertainFinishAndSessionWithoutSecondStart() async throws {
        for error: PublicationError in [.auth, .retryable, .root] {
            let record = try await captured(), fake = Fake(try await captured())
            await fake.setMetadataFailure()
            let upload = PublicationService(source: service) { _ in fake }
            await upload.run(id: record.id)
            let uncertain = try XCTUnwrap(service.journal.record(record.id))
            XCTAssertEqual(uncertain.error, .finishUncertain)
            await fake.setMetadataError(error)
            await upload.run(id: record.id)
            let retried = try XCTUnwrap(service.journal.record(record.id))
            XCTAssertEqual(retried.state, .verifying)
            XCTAssertEqual(retried.error, .finishUncertain)
            XCTAssertEqual(retried.uploadSession, uncertain.uploadSession)
            let counts = await fake.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
            try await upload.reconcileOutcome(id: record.id)
            XCTAssertEqual(try service.journal.record(record.id)?.state, .completed)
        }
    }

}
