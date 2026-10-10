import AppKit
import Foundation
import GRDB

@MainActor
final class DropboxPlaylistSyncCoordinator: ObservableObject {
    static let shared = DropboxPlaylistSyncCoordinator()
    @Published var status = "Connect Dropbox to share playlists with iPhone."
    @Published var isWorking = false
    @Published var states: [SyncPlaylistState] = []
    @Published var isPaired = false
    let authentication = DropboxPlaylistAuthentication()
    private var editObserver: NSObjectProtocol?
    private var scheduled: Task<Void, Never>?
    private var syncAgain = false
    private var db: DatabaseManager? { AppCoordinator.shared?.libraryManager.databaseManager }
    private init() {
        editObserver = NotificationCenter.default.addObserver(forName: .playlistSyncLocalEdit, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync() }
        }
    }
    func refreshStatus() {
        guard let db else { return }
        states = (try? db.syncStates()) ?? []
        isPaired = (try? db.syncPairing()) != nil
    }
    func scheduleSync() {
        refreshStatus()
        guard NSApp.isActive, isPaired else { return }
        scheduled?.cancel()
        scheduled = Task {
            do { try await Task.sleep(nanoseconds: 400_000_000); try Task.checkCancellation() }
            catch { return }
            await syncNow()
        }
    }
    func connect() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false; refreshStatus() }
        do { try await authentication.connect(); status = "Dropbox connected. Pair the matching music folder on both devices." }
        catch { status = safeMessage(error) }
    }
    func disconnect() {
        guard !isWorking else { return }
        do { try DropboxSyncVault.disconnect(); status = "Dropbox disconnected. Shared playlists and pending edits are retained." }
        catch { status = safeMessage(error) }
    }
    func pair(remotePath: String) async {
        guard !isWorking, let db else { return }
        let input = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.hasPrefix("/") || input.hasPrefix("id:") else { status = PlaylistSyncError.configuration.localizedDescription; return }
        let panel = NSOpenPanel()
        panel.title = "Choose the local folder matching your Dropbox music folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url else { return }
        isWorking = true
        defer { isWorking = false; refreshStatus() }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        do {
            let credentials = try await authentication.credentials()
            let account = try await DropboxPlaylistTransport(accessToken: credentials.accessToken).account()
            let client = DropboxPlaylistTransport(accessToken: credentials.accessToken, namespace: account.root_info.root_namespace_id)
            let music = try await client.metadata(input)
            guard music.tag == "folder", let folderID = music.id, let remoteRoot = music.path_display,
                  !remoteRoot.isEmpty else { throw PlaylistSyncError.configuration }
            // Validate an existing binding before any metadata write in a newly selected folder.
            let existingPairing = try db.syncPairing()
            let proposed = try Self.pairingDescriptor(existing: existingPairing, accountID: account.account_id,
                namespace: account.root_info.root_namespace_id, folderID: folderID,
                localRoot: root.standardizedFileURL.resolvingSymlinksInPath().path)
            let base = folderID + "/.crate-sync/v1"
            try await client.ensureFolder(DropboxPlaylistTransport.childPath(remoteRoot, ".crate-sync"))
            try await client.ensureFolder(DropboxPlaylistTransport.childPath(remoteRoot, ".crate-sync/v1"))
            let descriptor: SyncLibraryDescriptor
            do { descriptor = try JSONDecoder().decode(SyncLibraryDescriptor.self, from: await client.download(base + "/library.json")) }
            catch DropboxRequestError.notFound {
                let bytes = try JSONEncoder().encode(proposed)
                do {
                    try await client.immutableUpload(base + "/library.json", body: bytes)
                    descriptor = proposed
                } catch PlaylistSyncError.integrity {
                    // Simultaneous creator joins the verified winner, rather than overwriting it.
                    descriptor = try JSONDecoder().decode(SyncLibraryDescriptor.self, from: await client.download(base + "/library.json"))
                }
            }
            try descriptor.validate()
            guard descriptor.accountId == account.account_id, descriptor.namespaceId == account.root_info.root_namespace_id,
                  descriptor.musicFolderId == folderID else { throw PlaylistSyncError.pairingChanged }
            let bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try db.saveSyncPairing(SyncPairing(descriptor: descriptor, localRootBookmark: bookmark,
                localRootPath: root.standardizedFileURL.resolvingSymlinksInPath().path, remoteRootPath: remoteRoot))
            status = "Music folder paired. Share a manual playlist from its options menu."
        } catch { status = safeMessage(error) }
    }
    static func pairingDescriptor(existing: SyncPairing?, accountID: String, namespace: String, folderID: String, localRoot: String) throws -> SyncLibraryDescriptor {
        if let existing {
            guard existing.descriptor.accountId == accountID, existing.descriptor.namespaceId == namespace,
                  existing.descriptor.musicFolderId == folderID, existing.localRootPath == localRoot else { throw PlaylistSyncError.pairingChanged }
            return existing.descriptor
        }
        return SyncLibraryDescriptor(libraryId: UUID().uuidString.lowercased(), accountId: accountID, namespaceId: namespace, musicFolderId: folderID)
    }
    func share(_ playlist: Playlist) {
        guard let db else { return }
        do { try db.sharePlaylist(playlist.id); status = "Playlist selected for sharing."; scheduleSync() }
        catch { status = safeMessage(error) }
        refreshStatus()
    }
    private func safeMessage(_ error: Error) -> String {
        (error as? PlaylistSyncError)?.localizedDescription ?? "Dropbox sync could not finish. Pending changes are retained; retry Sync Now."
    }
    func syncNow() async {
        if isWorking { syncAgain = true; return }
        guard let db else { return }
        isWorking = true; syncAgain = false
        defer {
            isWorking = false; refreshStatus()
            if syncAgain { syncAgain = false; scheduleSync() }
        }
        do {
            guard let pairing = try db.syncPairing() else { throw PlaylistSyncError.notPaired }
            let credentials = try await authentication.credentials()
            let account = try await DropboxPlaylistTransport(accessToken: credentials.accessToken).account()
            guard account.account_id == pairing.descriptor.accountId, account.root_info.root_namespace_id == pairing.descriptor.namespaceId else { throw PlaylistSyncError.pairingChanged }
            let client = DropboxPlaylistTransport(accessToken: credentials.accessToken, namespace: pairing.descriptor.namespaceId)
            let music = try await client.metadata(pairing.descriptor.musicFolderId)
            guard music.tag == "folder", music.id == pairing.descriptor.musicFolderId else { throw PlaylistSyncError.pairingChanged }
            let descriptor = try JSONDecoder().decode(SyncLibraryDescriptor.self, from: await client.download(pairing.descriptor.musicFolderId + "/.crate-sync/v1/library.json"))
            try descriptor.validate()
            guard descriptor == pairing.descriptor else { throw PlaylistSyncError.pairingChanged }
            var stale = false
            let root = try URL(resolvingBookmarkData: pairing.localRootBookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, root.standardizedFileURL.resolvingSymlinksInPath().path == pairing.localRootPath else { throw PlaylistSyncError.pairingChanged }
            let accessing = root.startAccessingSecurityScopedResource()
            defer { if accessing { root.stopAccessingSecurityScopedResource() } }
            status = "Syncing playlists…"
            var activePairing = pairing
            guard let liveRootPath = music.path_display else { throw PlaylistSyncError.pairingChanged }
            activePairing.remoteRootPath = liveRootPath
            var blocked = 0
            for state in try db.syncStates() {
                guard let intent = state.intent else { continue }
                do {
                    var resolved: [Int64: String] = [:]
                    for member in intent.members where member.fileId == nil {
                        guard let id = member.localTrackID else { throw PlaylistSyncError.mappingBlocked }
                        resolved[id] = try await mapLocal(id, snapshotPath: member.localPath, root: root, pairing: activePairing, client: client, db: db)
                    }
                    _ = try db.materializeSyncIntent(state.localID, generation: intent.generation, resolved: resolved)
                } catch PlaylistSyncError.authentication { throw PlaylistSyncError.authentication }
                catch PlaylistSyncError.pairingChanged { throw PlaylistSyncError.pairingChanged }
                catch PlaylistSyncError.integrity { throw PlaylistSyncError.integrity }
                catch { blocked += 1; try db.setSyncIssue(state.localID, issue: "mapping") }
            }
            // Commit every page's download obligations before its durable cursor advances.
            var cursor = try db.syncCursor(), more = true
            while more {
                let page: DropboxSyncPage
                do { page = try await client.list(pairing.descriptor.musicFolderId + "/.crate-sync/v1", cursor: cursor) }
                catch DropboxRequestError.cursorReset { try db.resetSyncCursor(); cursor = nil; continue }
                let prefix = (music.path_display ?? pairing.remoteRootPath).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
                let paths = page.entries.compactMap { entry -> String? in
                    guard entry.tag == "file", let path = entry.path_display else { return nil }
                    let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard normalized.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
                    let relative = String(normalized.dropFirst(prefix.count))
                    guard relative.hasPrefix(".crate-sync/v1/playlists/"), relative.hasSuffix(".json") else { return nil }
                    return relative
                }
                try db.saveSyncDiscovery(paths: paths, cursor: page.cursor)
                cursor = page.cursor; more = page.has_more
            }
            var pendingErrors = 0
            for path in try db.syncIncomingPaths() {
                do {
                    let body = try await client.download(pairing.descriptor.musicFolderId + "/" + path)
                    try db.receiveSyncRevision(body, path: path, library: pairing.descriptor.libraryId)
                } catch { pendingErrors += 1; try db.failSyncIncoming(path, error: safeMessage(error)) }
            }
            // Mapping failure affects projection only; full remote references stay durable.
            for ref in try db.allSyncFileIDs() {
                do { try await mapRemote(ref, root: root, pairing: activePairing, client: client, db: db) }
                catch PlaylistSyncError.authentication { throw PlaylistSyncError.authentication }
                catch PlaylistSyncError.pairingChanged { throw PlaylistSyncError.pairingChanged }
                catch PlaylistSyncError.mappingBlocked { try db.invalidateSyncMapping(ref) }
                catch DropboxRequestError.notFound { try db.invalidateSyncMapping(ref) }
                catch { /* Transient transport failure retains earlier verified mapping. */ }
            }
            // Exact bodies in immutable queue order; failed parent stops this playlist's chain.
            var failedPlaylists = Set<String>(), uploadsFailed = 0
            for (id, body) in try db.syncOutbox() {
                let revision = try PlaylistRevision.decode(body, library: pairing.descriptor.libraryId)
                if failedPlaylists.contains(revision.playlistId) { continue }
                do {
                    let base = DropboxPlaylistTransport.childPath(liveRootPath, ".crate-sync/v1/playlists")
                    try await client.ensureFolder(base)
                    try await client.ensureFolder(base + "/" + revision.playlistId)
                    try await client.immutableUpload(pairing.descriptor.musicFolderId + "/" + revision.path, body: body)
                    try db.acknowledgeSyncRevision(id)
                } catch PlaylistSyncError.authentication { throw PlaylistSyncError.authentication }
                catch PlaylistSyncError.integrity { throw PlaylistSyncError.integrity }
                catch { failedPlaylists.insert(revision.playlistId); uploadsFailed += 1 }
            }
            try db.projectSyncRevisions()
            AppCoordinator.shared?.playlistManager.loadPlaylists()
            refreshStatus()
            let conflicts = states.filter { $0.issue == "conflict" }.count
            let incomplete = states.filter { $0.issue == "incomplete" || $0.issue == "invalid" }.count
            let missing = states.flatMap(\.members).filter { $0.localTrackID == nil }.count
            status = blocked + pendingErrors + uploadsFailed + conflicts + incomplete + missing == 0 ? "Playlists synchronized." :
                "\(blocked) blocked, \(conflicts) conflicts, \(incomplete + pendingErrors) pending, \(uploadsFailed) failed uploads, \(missing) unavailable songs. Retry or resolve below."
        } catch { status = safeMessage(error) }
    }
    private func mapLocal(_ id: Int64, snapshotPath: String?, root: URL, pairing: SyncPairing, client: DropboxPlaylistTransport, db: DatabaseManager) async throws -> String {
        guard let path = snapshotPath else { throw PlaylistSyncError.mappingBlocked }
        let local = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard local.path.hasPrefix(prefix) else { throw PlaylistSyncError.mappingBlocked }
        let relative = String(local.path.dropFirst(prefix.count))
        guard !relative.split(separator: "/").contains(".crate-sync") else { throw PlaylistSyncError.mappingBlocked }
        let remote = try await client.metadata(pairing.descriptor.musicFolderId + "/" + relative)
        guard remote.tag == "file", let fileID = remote.id, let expectedHash = remote.content_hash else { throw PlaylistSyncError.mappingBlocked }
        let hash = try await Task.detached(priority: .utility) { try DropboxPlaylistTransport.contentHash(local) }.value
        guard hash == expectedHash else { throw PlaylistSyncError.mappingBlocked }
        try db.saveSyncMapping(fileID: fileID, trackID: id, hash: hash, expectedPath: path)
        return fileID
    }
    private func mapRemote(_ fileID: String, root: URL, pairing: SyncPairing, client: DropboxPlaylistTransport, db: DatabaseManager) async throws {
        try await DropboxPlaylistMapping.refreshRemote(fileID, root: root, remoteRootPath: pairing.remoteRootPath, client: client, db: db)
    }

    func resolve(_ state: SyncPlaylistState) {
        guard !isWorking, let db else { return }
        do {
            let versions = try db.syncRevisions(state.sharedID).filter { state.heads.contains($0.revisionId) }.sorted { $0.revisionId < $1.revisionId }
            guard versions.count > 1 else { return }
            let alert = NSAlert()
            alert.messageText = "Resolve playlist conflict"
            alert.informativeText = "Choose the version to keep for this shared playlist. Keep Both also publishes the second selected version as a new conflict copy. All original revisions remain recoverable."
            alert.addButton(withTitle: "Use Selected"); alert.addButton(withTitle: "Keep Both"); alert.addButton(withTitle: "Cancel")
            let chosen = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
            let other = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
            let titles = versions.map { "\($0.name) — \($0.deleted ? "Deleted" : "\($0.tracks.count) songs") (\($0.deviceId.prefix(8)))" }
            chosen.addItems(withTitles: titles); other.addItems(withTitles: titles); other.selectItem(at: 1)
            let stack = NSStackView(views: [NSTextField(labelWithString: "Shared version:"), chosen,
                NSTextField(labelWithString: "Version to copy with Keep Both:"), other])
            stack.orientation = .vertical; stack.alignment = .leading
            alert.accessoryView = stack
            let result = alert.runModal()
            guard result != .alertThirdButtonReturn else { return }
            let copy = result == .alertSecondButtonReturn ? versions[other.indexOfSelectedItem] : nil
            if let copy, copy.revisionId == versions[chosen.indexOfSelectedItem].revisionId || copy.deleted { throw PlaylistSyncError.configuration }
            try db.resolveSyncConflict(localID: state.localID, chosen: versions[chosen.indexOfSelectedItem].revisionId,
                expectedHeads: state.heads, keepBoth: copy?.revisionId)
            AppCoordinator.shared?.playlistManager.loadPlaylists()
            status = "Conflict resolution queued."; scheduleSync()
        } catch { status = safeMessage(error) }
        refreshStatus()
    }
}
extension DatabaseManager {
    func setSyncIssue(_ id: UUID, issue: String) throws {
        try dbQueue.write { try $0.execute(sql: "UPDATE playlist_sync_state SET issue = ? WHERE local_id = ?", arguments: [issue, id.uuidString]) }
    }
    func allSyncFileIDs() throws -> [String] {
        try dbQueue.read { db in
            let bodies = try Data.fetchAll(db, sql: "SELECT body FROM playlist_sync_revision")
            return try Set(bodies.flatMap { try PlaylistRevision.decode($0).tracks.map(\.fileId) }).sorted()
        }
    }
}
