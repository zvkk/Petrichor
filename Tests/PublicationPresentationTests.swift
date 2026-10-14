import XCTest
import SwiftUI
import AppKit
@testable import Petrichor

final class PublicationPresentationTests: PublicationTestCase {
    @MainActor
    func coordinator(settings: @escaping () -> Void = {}) -> PublicationCoordinator {
        PublicationCoordinator(manager: manager, source: service,
            service: PublicationService(source: service) { _ in throw PublicationError.retryable },
            connectionReady: { true }, openSettings: settings)
    }
    @MainActor
    func waitForPreparation(_ model: PublicationCoordinator) async throws {
        for _ in 0..<200 {
            if !model.preparing { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Preparation timed out")
    }
    @MainActor
    func testCancelBeforeConfirmationHasNoCaptureOrCopy() async throws {
        var captures = 0
        service.afterCapture = { captures += 1 }
        let model = coordinator()
        model.request(trackIDs: [trackID])
        try await waitForPreparation(model)
        XCTAssertTrue(model.showingConfirmation)
        XCTAssertEqual(model.selection.map(\.id), [trackID])
        XCTAssertEqual(model.selection.first?.size, 5 * 1024 * 1024 + 17)
        XCTAssertTrue(model.selection.first?.outsideRoot == true)
        model.dismissConfirmation()
        XCTAssertEqual(captures, 0)
        XCTAssertTrue(try service.journal.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("original.wav").path))
    }
    @MainActor
    func testUnpairedOpensConnectionSettingsWithoutCapture() async throws {
        try await manager.dbQueue.write { db in try db.execute(sql: "DELETE FROM playlist_sync_meta WHERE key='pairing'") }
        var settings = 0
        let model = coordinator { settings += 1 }
        model.request(trackIDs: [trackID])
        try await waitForPreparation(model)
        XCTAssertNil(try manager.syncPairing())
        XCTAssertEqual(settings, 1)
        XCTAssertFalse(model.showingConfirmation)
        XCTAssertTrue(try service.journal.all().isEmpty)
    }
    @MainActor
    func testSubmitRequiresOutsideCopyConsentAndValidPaths() async throws {
        let model = coordinator()
        model.request(trackIDs: [trackID])
        try await waitForPreparation(model)
        model.submit(copyConsent: false)
        XCTAssertTrue(model.showingConfirmation)
        guard model.showingConfirmation else { return }
        model.selection[0].destination = "../escape.wav"
        model.submit(copyConsent: true)
        XCTAssertTrue(model.showingConfirmation)
        XCTAssertTrue(try service.journal.all().isEmpty)
    }
    @MainActor
    func testMixedResultsRestoreWithoutStartingProvider() async throws {
        let id = try await service.capture(trackID: trackID, destinationRelativePath: "approved.wav", confirmedOutsideRootCopy: true)
        let record = try XCTUnwrap(service.journal.record(id))
        let transport = PublicationServiceTests.Fake(record)
        await PublicationService(source: service) { _ in transport }.run(id: id)
        let failed = try await service.capture(trackID: trackID, destinationRelativePath: "failed.wav", confirmedOutsideRootCopy: true)
        await PublicationService(source: service) { _ in throw PublicationError.quota }.run(id: failed)
        let model = coordinator()
        await model.refresh()
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows.filter { $0.state == .completed }.count, 1)
        XCTAssertEqual(model.rows.filter { $0.state == .failed }.count, 1)
        XCTAssertEqual(PublicationCoordinator.result(try XCTUnwrap(model.rows.first { $0.id == id })), String(localized: "Added"))
        XCTAssertEqual(PublicationCoordinator.result(try XCTUnwrap(model.rows.first { $0.id == failed })), String(localized: "Failed"))
        try render(PublicationResults(coordinator: model), name: "mixed-results", size: NSSize(width: 350, height: 380))
    }
    @MainActor
    func testConfirmationFixtureRender() async throws {
        let model = coordinator()
        model.request(trackIDs: [trackID])
        try await waitForPreparation(model)
        try render(PublicationSheet(coordinator: model), name: "confirmation", size: NSSize(width: 520, height: 520))
    }
    @MainActor
    func testDisconnectedRetainedPairingOpensSettings() async throws {
        var settings = 0
        let model = PublicationCoordinator(manager: manager, source: service, connectionReady: { false }, openSettings: { settings += 1 })
        model.request(trackIDs: [trackID])
        XCTAssertEqual(settings, 1)
        XCTAssertFalse(model.showingConfirmation)
        XCTAssertTrue(try service.journal.all().isEmpty)
    }
    @MainActor
    func testConnectionChangeWhileConfirmingDoesNotCopy() async throws {
        let model = coordinator()
        model.request(trackIDs: [trackID])
        try await waitForPreparation(model)
        PublicationConnectionEpoch.shared.invalidate()
        model.submit(copyConsent: true)
        XCTAssertFalse(model.showingConfirmation)
        XCTAssertTrue(try service.journal.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("original.wav").path))
    }
    @MainActor
    func testPairingChangeAfterConfirmationRejectsApprovedRoot() async throws {
        let model = coordinator()
        model.request(trackIDs: [trackID])
        try await waitForPreparation(model)
        var pairing = try XCTUnwrap(manager.syncPairing())
        pairing = SyncPairing(descriptor: pairing.descriptor, localRootBookmark: pairing.localRootBookmark,
            localRootPath: directory.appendingPathComponent("unapproved").path, remoteRootPath: "/unapproved")
        let data = try JSONEncoder().encode(pairing)
        try await manager.dbQueue.write { db in try db.execute(sql: "UPDATE playlist_sync_meta SET value=? WHERE key='pairing'", arguments: [data]) }
        model.submit(copyConsent: true)
        for _ in 0..<100 {
            if model.issue != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(model.issue)
        XCTAssertTrue(try service.journal.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairing.localRootPath))
    }
    func testApprovedBatchIsDurableBeforeCaptureAndCancellationIsRetained() async throws {
        let ids = try service.prepareIntents([(trackID, "first.wav"), (trackID, "second.wav"), (trackID, "third.wav")])
        XCTAssertEqual(try service.journal.all().count, 3)
        XCTAssertTrue(try service.journal.all().allSatisfy { !$0.snapshot.isReady })
        try service.journal.cancel(ids[2])
        do { _ = try await service.capturePrepared(id: ids[2], confirmedOutsideRootCopy: true); XCTFail("Cancelled intent captured") } catch {}
        XCTAssertEqual(try service.journal.record(ids[2])?.state, .cancelled)
        try service.journal.recoverInterruptedCaptures()
        XCTAssertEqual(try service.journal.all().filter { $0.state == .failed }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("third.wav").path))
    }
    func testUnavailableBookmarkRecordsOneDurableSelectedFailure() async throws {
        try await manager.dbQueue.write { db in try db.execute(sql: "UPDATE folders SET bookmark_data=NULL") }
        do { _ = try await service.capture(trackID: trackID, destinationRelativePath: "failed-access.wav", confirmedOutsideRootCopy: true); XCTFail("Missing bookmark captured") } catch {}
        let rows = try service.journal.all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].state, .failed)
        XCTAssertEqual(rows[0].error, .unavailableSource)
        XCTAssertEqual(rows[0].snapshot.sourcePath, original.path)
    }
    @MainActor
    func testUncertainRecoveryUsesReadOnlyServiceBoundary() async throws {
        let id = try await service.capture(trackID: trackID, destinationRelativePath: "uncertain.wav", confirmedOutsideRootCopy: true)
        var row = try XCTUnwrap(service.journal.record(id))
        row.state = .verifying; row.error = .finishUncertain
        try service.journal.save(row)
        try service.journal.cancel(id)
        let fake = PublicationServiceTests.Fake(row)
        await fake.setRemote(PublicationRemoteProof(fileID: "id:outcome", contentHash: row.snapshot.dropboxHash!, size: UInt64(row.snapshot.sourceIdentity!.size)))
        let upload = PublicationService(source: service) { _ in fake }
        let model = PublicationCoordinator(manager: manager, source: service, service: upload, connectionReady: { true }, openSettings: {})
        await model.refresh()
        model.recover(try XCTUnwrap(model.rows.first))
        for _ in 0..<200 {
            if try service.journal.record(id)?.state == .completed { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(try service.journal.record(id)?.state, .completed)
        let starts = await fake.starts, finishes = await fake.finishes
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(finishes, 0)
    }
    @MainActor
    func testNewNameRecoveryRequiresChangedExplicitDestination() async throws {
        let id = try await service.capture(trackID: trackID, destinationRelativePath: "original.wav", confirmedOutsideRootCopy: true)
        var row = try XCTUnwrap(service.journal.record(id))
        row.state = .failed; row.error = .needsNewName
        try service.journal.save(row)
        let model = coordinator()
        model.recover(row)
        try await waitForPreparation(model)
        XCTAssertTrue(model.showingConfirmation)
        XCTAssertEqual(model.selection[0].rejectedDestination, "original.wav")
        model.submit(copyConsent: true)
        XCTAssertTrue(model.showingConfirmation)
        XCTAssertEqual(try service.journal.all().count, 1)
        model.dismissConfirmation()
    }
    @MainActor
    private func render<V: View>(_ view: V, name: String, size: NSSize) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
