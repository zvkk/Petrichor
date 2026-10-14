import Foundation
import GRDB

struct PublicationSelection: Identifiable {
    let id: Int64
    let title: String
    let sourcePath: String
    let size: Int64?
    let outsideRoot: Bool
    var destination: String
    var rejectedDestination: String?
}

/// Presentation owns consent; only submit crosses the capture boundary.
@MainActor
final class PublicationCoordinator: ObservableObject {
    static let shared = PublicationCoordinator()
    @Published var selection: [PublicationSelection] = []
    @Published var showingConfirmation = false
    @Published var rows: [Publication] = []
    @Published var destinationFolder = ""
    @Published var issue: String?
    @Published var preparing = false
    @Published private(set) var activeIDs: Set<PublicationID> = []
    private var source: PublicationSource?
    private var service: PublicationService?
    private var manager: DatabaseManager?
    private var polling: Task<Void, Never>?
    private var running: Set<PublicationID> = []
    private var confirmationPairing: SyncPairing?
    private var confirmationEpoch: UInt64?
    private var activeBatches = 0
    private var activeJobs = 0
    private var jobWaiters: [CheckedContinuation<Void, Never>] = []
    private let connectionReady: @MainActor () -> Bool
    private let openSettings: @MainActor () -> Void

    init(manager: DatabaseManager? = nil, source: PublicationSource? = nil,
         service: PublicationService? = nil, connectionReady: @escaping @MainActor () -> Bool = {
             DropboxPlaylistSyncCoordinator.shared.refreshStatus()
             return DropboxPlaylistSyncCoordinator.shared.isConnected
         }, openSettings: @escaping @MainActor () -> Void = {
             DropboxPlaylistSyncCoordinator.shared.openConnectionSettings()
         }) {
        self.manager = manager; self.source = source; self.service = service; self.openSettings = openSettings
        self.connectionReady = connectionReady
    }
    func configure(_ manager: DatabaseManager) {
        guard self.manager == nil else { return }
        self.manager = manager
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.Petrichor.publication")
            .appendingPathComponent("PublicationSnapshots")
        let source = PublicationSource(manager: manager, snapshotDirectory: base)
        self.source = source
        let authentication = DropboxPlaylistSyncCoordinator.shared.authentication
        self.service = PublicationService(source: source) { record in
            try await DropboxPublicationTransport.verified(record: record, manager: manager, authentication: authentication)
        }
        Task {
            try? await Task.detached(priority: .utility) { try source.journal.recoverInterruptedCaptures() }.value
            await refresh()
        }
    }
    func request(trackIDs: [Int64], rejectedDestination: String? = nil) {
        guard !trackIDs.isEmpty, !preparing, !showingConfirmation, let manager else { return }
        guard connectionReady() else { openSettings(); return }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                let epoch = PublicationConnectionEpoch.shared.current()
                let prepared = try await Task.detached(priority: .utility) {
                    guard let pairing = try manager.syncPairing() else { throw PublicationError.unavailableScope }
                    let prefix = pairing.localRootPath.hasSuffix("/") ? pairing.localRootPath : pairing.localRootPath + "/"
                    let entries = try manager.dbQueue.read { db in
                        try Array(Set(trackIDs)).sorted().map { id -> PublicationSelection in
                            guard let row = try Row.fetchOne(db, sql: "SELECT path, title, filename FROM tracks WHERE id=?", arguments: [id]) else { throw PublicationError.unavailableSource }
                            let path: String = row["path"]
                            let outside = !path.hasPrefix(prefix)
                            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
                            let title = (row["title"] as String?) ?? (row["filename"] as String? ?? URL(fileURLWithPath: path).lastPathComponent)
                            return PublicationSelection(id: id, title: title, sourcePath: path, size: size, outsideRoot: outside,
                                destination: outside ? URL(fileURLWithPath: path).lastPathComponent : String(path.dropFirst(prefix.count)), rejectedDestination: rejectedDestination)
                        }
                    }
                    return (pairing, entries)
                }.value
                confirmationPairing = prepared.0; confirmationEpoch = epoch
                destinationFolder = prepared.0.remoteRootPath; selection = prepared.1; issue = nil; showingConfirmation = true
            } catch PublicationError.unavailableScope { openSettings() }
            catch { issue = String(localized: "The selected recordings could not be prepared. Check their file access and try again.") }
        }
    }
    func dismissConfirmation() { showingConfirmation = false; selection = []; confirmationPairing = nil; confirmationEpoch = nil }
    func submit(copyConsent: Bool) {
        guard showingConfirmation, let source, let service,
              !selection.isEmpty, !selection.contains(where: { $0.outsideRoot && !copyConsent }),
              selection.allSatisfy({ (try? PublicationSource.components($0.destination)) != nil && $0.destination != $0.rejectedDestination }),
              Set(selection.map { $0.destination.lowercased() }).count == selection.count else { return }
        guard let pairing = confirmationPairing, let epoch = confirmationEpoch,
              connectionReady(), PublicationConnectionEpoch.shared.current() == epoch else {
            issue = String(localized: "The connection changed. Review the destination again before adding recordings.")
            dismissConfirmation(); openSettings(); return
        }
        let approved = selection
        dismissConfirmation()
        activeBatches += 1
        Task {
            do {
                let ids = try await Task.detached(priority: .utility) {
                    try source.prepareIntents(approved.map { ($0.id, $0.destination) }, expectedPairing: pairing, expectedConnectionEpoch: epoch,
                        expectedPaths: Dictionary(uniqueKeysWithValues: approved.map { ($0.id, $0.sourcePath) }))
                }.value
                activeIDs.formUnion(ids)
                await refresh()
                // At most two complete capture/upload jobs, including local copies.
                for start in stride(from: 0, to: ids.count, by: 2) {
                    await withTaskGroup(of: Void.self) { group in
                        for id in ids[start..<min(start + 2, ids.count)] {
                            group.addTask {
                                await self.acquireJob()
                                do {
                                    _ = try await Task.detached(priority: .utility) {
                                        try await source.capturePrepared(id: id, confirmedOutsideRootCopy: copyConsent, expectedConnectionEpoch: epoch)
                                    }.value
                                    await self.perform(id, service: service, outcomeOnly: false)
                                } catch { await self.captureFailed() }
                                await self.finishJob(id)
                            }
                        }
                    }
                }
            } catch { captureFailed() }
            activeBatches -= 1
            await refresh()
        }
        startPolling()
    }
    private func acquireJob() async {
        if activeJobs < 2 { activeJobs += 1; return }
        await withCheckedContinuation { jobWaiters.append($0) }
    }
    private func finishJob(_ id: PublicationID) {
        activeIDs.remove(id)
        if jobWaiters.isEmpty { activeJobs -= 1 } else { jobWaiters.removeFirst().resume() }
    }
    func setUpConnection() { openSettings() }
    private func captureFailed() { issue = String(localized: "A recording could not be captured. Review its result and try again.") }
    func refresh() async {
        guard let source else { return }
        do { rows = try await Task.detached(priority: .utility) { try source.journal.all() }.value }
        catch { issue = String(localized: "Shared music results could not be read. Try again.") }
    }
    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
                if self.activeBatches == 0 && self.running.isEmpty && self.activeIDs.isEmpty { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.polling = nil
        }
    }
    private func perform(_ id: PublicationID, service: PublicationService, outcomeOnly: Bool) async {
        guard running.insert(id).inserted else { return }
        activeIDs.insert(id)
        defer { running.remove(id); activeIDs.remove(id) }
        if outcomeOnly {
            do { try await service.reconcileOutcome(id: id) }
            catch { issue = String(localized: "The outcome could not be checked. The uncertain result is retained; check your connection and try again.") }
        }
        else { await service.run(id: id) }
        await refresh()
    }
    func cancel(_ id: PublicationID) {
        guard let service else { return }
        Task { try? await service.cancel(id: id); await refresh() }
    }
    private func recoverUsingSlot(_ id: PublicationID, service: PublicationService, outcomeOnly: Bool) async {
        guard !activeIDs.contains(id) else { return }
        activeIDs.insert(id)
        await acquireJob()
        await perform(id, service: service, outcomeOnly: outcomeOnly)
        finishJob(id)
    }
    func recover(_ row: Publication) {
        guard let service else { return }
        if row.error == .finishUncertain {
            Task { await recoverUsingSlot(row.id, service: service, outcomeOnly: true) }; startPolling()
        } else if row.error == .auth && !connectionReady() {
            openSettings()
        } else if row.state == .cancelled || !row.snapshot.isReady || [.sourceChanged, .needsNewName, .unavailableSource, .unavailableScope, .root, .integrity, .contentMismatch].contains(row.error) {
            request(trackIDs: [row.trackID], rejectedDestination: row.error == .needsNewName ? row.destination : nil)
        } else {
            Task { await recoverUsingSlot(row.id, service: service, outcomeOnly: false) }; startPolling()
        }
    }
    static func explanation(_ row: Publication) -> String? {
        switch row.error {
        case .auth: return String(localized: "Reconnect Dropbox in connection settings, then retry.")
        case .root: return String(localized: "Review the paired music folder in connection settings, then retry.")
        case .quota: return String(localized: "Free space in Dropbox, then retry this recording.")
        case .sourceChanged, .unavailableSource, .unavailableScope, .integrity, .contentMismatch:
            return String(localized: "Check the original recording and file access. Retry opens a fresh confirmation when new capture is needed.")
        case .needsNewName: return String(localized: "Choose and approve another destination path. Existing recordings are preserved.")
        case .finishUncertain: return String(localized: "Check outcome reads the destination without uploading again.")
        default: return nil
        }
    }
    static func result(_ row: Publication) -> String {
        if row.state == .completed { return row.uploadSession == nil ? String(localized: "Already shared") : String(localized: "Added") }
        if row.error == .finishUncertain { return String(localized: "Outcome uncertain") }
        if row.error == .needsNewName { return String(localized: "Needs a new name") }
        if row.error == .sourceChanged { return String(localized: "Source changed") }
        switch row.state {
        case .cancelled: return String(localized: "Cancelled")
        case .failed: return String(localized: "Failed")
        case .queued: return String(localized: "Queued — resume when ready")
        case .capturing: return row.snapshot.sourceIdentity == nil ? String(localized: "Waiting to capture") : String(localized: "Capturing")
        case .uploading: return String(localized: "Uploading")
        case .verifying: return String(localized: "Verifying")
        case .completed: return String(localized: "Added")
        }
    }
}
