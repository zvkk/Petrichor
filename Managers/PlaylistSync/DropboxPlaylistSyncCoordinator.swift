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
    @Published var isConnected = false
    @Published var musicFolder = "No music folder chosen"
    @Published var queuedCrates: Set<String> = []
    @Published var recovery: String?
    @Published var pairingDetails = ""
    let authentication = DropboxPlaylistAuthentication()
    private var editObserver: NSObjectProtocol?
    private var scheduled: Task<Void, Never>?
    private var syncAgain = false
    private var savedConnection: Bool?
    private var db: DatabaseManager? { AppCoordinator.shared?.libraryManager.databaseManager }
    private init() {
        editObserver = NotificationCenter.default.addObserver(forName: .playlistSyncLocalEdit, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync() }
        }
    }
    func refreshStatus() {
        guard let db else { return }
        states = (try? db.syncStates()) ?? []
        let pairing = try? db.syncPairing()
        isPaired = pairing != nil
        if savedConnection == nil { savedConnection = DropboxSyncVault.hasSavedCredentials() }
        isConnected = savedConnection == true
        musicFolder = pairing?.remoteRootPath == "/" ? "Crate App folder" : (pairing?.remoteRootPath ?? "No music folder chosen")
        pairingDetails = pairing.map { "Dropbox folder: \($0.descriptor.musicFolderId)\nLibrary: \($0.descriptor.libraryId)\nLocal folder: \($0.localRootPath)" } ?? "Not paired"
        queuedCrates = Set(((try? db.syncOutbox()) ?? []).compactMap { try? PlaylistRevision.decode($0.1).playlistId })
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
        do { try await authentication.connect(); savedConnection = true; recovery = nil; status = "Dropbox connected. Pair the matching music folder on both devices." }
        catch { status = safeMessage(error) }
    }
    func disconnect() {
        guard !isWorking else { return }
        do { try DropboxSyncVault.disconnect(); savedConnection = false; recovery = nil; status = "Dropbox disconnected. Shared crates and pending edits are retained."; refreshStatus() }
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
            let credentials = try await authentication.credentials(forceRefresh: input == "/")
            let account = try await DropboxPlaylistTransport(accessToken: credentials.accessToken).account()
            let client = DropboxPlaylistTransport(accessToken: credentials.accessToken, namespace: account.root_info.root_namespace_id)
            let music = try await client.musicFolder(input, appKey: authentication.appKey)
            guard music.tag == "folder", let folderID = music.id, let remoteRoot = music.path_display else { throw PlaylistSyncError.configuration }
            // Validate an existing binding before any metadata write in a newly selected folder.
            let existingPairing = try db.syncPairing()
            let proposed = try Self.pairingDescriptor(existing: existingPairing, accountID: account.account_id,
                namespace: account.root_info.root_namespace_id, folderID: folderID,
                localRoot: root.standardizedFileURL.resolvingSymlinksInPath().path)
            let base = client.musicPath(folderID, ".crate-sync/v1")
            let descriptor: SyncLibraryDescriptor
            do { descriptor = try JSONDecoder().decode(SyncLibraryDescriptor.self, from: await client.download(base + "/library.json")) }
            catch DropboxRequestError.notFound {
                guard existingPairing == nil else { throw PlaylistSyncError.pairingChanged }
                try await client.ensureFolder(DropboxPlaylistTransport.childPath(remoteRoot, ".crate-sync"))
                try await client.ensureFolder(DropboxPlaylistTransport.childPath(remoteRoot, ".crate-sync/v1"))
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
                  descriptor.musicFolderId == folderID,
                  existingPairing == nil || descriptor == existingPairing?.descriptor else { throw PlaylistSyncError.pairingChanged }
            try await client.ensureFolder(DropboxPlaylistTransport.childPath(remoteRoot, ".crate-sync/v1/playlists"))
            let bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try db.saveSyncPairing(SyncPairing(descriptor: descriptor, localRootBookmark: bookmark,
                localRootPath: root.standardizedFileURL.resolvingSymlinksInPath().path, remoteRootPath: remoteRoot))
            recovery = nil
            status = "Music folder paired. Share a crate from its options menu."
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
        guard playlist.type == .regular, playlist.isUserEditable, playlist.isContentEditable, let db else { return }
        do { try db.sharePlaylist(playlist.id); status = "Crate selected for sharing."; scheduleSync() }
        catch { status = safeMessage(error) }
        refreshStatus()
    }
    private func safeMessage(_ error: Error) -> String {
        if let failure = error as? PlaylistSyncError {
            switch failure {
            case .authentication, .writePermission: recovery = "Reconnect Dropbox"
            case .pairingChanged, .notPaired, .configuration: recovery = "Check music folder"
            default: break
            }
        }
        return (error as? PlaylistSyncError)?.localizedDescription ?? "Dropbox sync could not finish. Pending changes are retained; retry Sync now."
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
            let credentials = try await authentication.credentials(forceRefresh: pairing.descriptor.musicFolderId.hasPrefix("app-folder:"))
            let account = try await DropboxPlaylistTransport(accessToken: credentials.accessToken).account()
            guard account.account_id == pairing.descriptor.accountId, account.root_info.root_namespace_id == pairing.descriptor.namespaceId else { throw PlaylistSyncError.pairingChanged }
            let client = DropboxPlaylistTransport(accessToken: credentials.accessToken, namespace: pairing.descriptor.namespaceId)
            let music = try await client.musicFolder(pairing.descriptor.musicFolderId, appKey: authentication.appKey)
            guard music.tag == "folder", music.id == pairing.descriptor.musicFolderId else { throw PlaylistSyncError.pairingChanged }
            let descriptor = try JSONDecoder().decode(SyncLibraryDescriptor.self, from: await client.download(client.musicPath(pairing.descriptor.musicFolderId, ".crate-sync/v1/library.json")))
            try descriptor.validate()
            guard descriptor == pairing.descriptor else { throw PlaylistSyncError.pairingChanged }
            var stale = false
            let root = try URL(resolvingBookmarkData: pairing.localRootBookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, root.standardizedFileURL.resolvingSymlinksInPath().path == pairing.localRootPath else { throw PlaylistSyncError.pairingChanged }
            let accessing = root.startAccessingSecurityScopedResource()
            defer { if accessing { root.stopAccessingSecurityScopedResource() } }
            recovery = nil
            status = "Syncing…"
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
                catch PlaylistSyncError.writePermission { throw PlaylistSyncError.writePermission }
                catch PlaylistSyncError.pairingChanged { throw PlaylistSyncError.pairingChanged }
                catch PlaylistSyncError.integrity { throw PlaylistSyncError.integrity }
                catch { blocked += 1; try db.setSyncIssue(state.localID, issue: "mapping") }
            }
            // Commit every page's download obligations before its durable cursor advances.
            var cursor = try db.syncCursor(), more = true
            while more {
                let page: DropboxSyncPage
                do { page = try await client.list(client.musicPath(pairing.descriptor.musicFolderId, ".crate-sync/v1"), cursor: cursor) }
                catch DropboxRequestError.cursorReset { try db.resetSyncCursor(); cursor = nil; continue }
                let prefix = DropboxPlaylistTransport.childPath(liveRootPath, "")
                let paths = page.entries.compactMap { entry -> String? in
                    guard entry.tag == "file", let path = entry.path_display else { return nil }
                    let normalized = path
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
                    let body = try await client.download(client.musicPath(pairing.descriptor.musicFolderId, path))
                    try db.receiveSyncRevision(body, path: path, library: pairing.descriptor.libraryId)
                } catch { pendingErrors += 1; try db.failSyncIncoming(path, error: safeMessage(error)) }
            }
            // Mapping failure affects projection only; full remote references stay durable.
            for ref in try db.allSyncFileIDs() {
                do { try await mapRemote(ref, root: root, pairing: activePairing, client: client, db: db) }
                catch PlaylistSyncError.authentication { throw PlaylistSyncError.authentication }
                catch PlaylistSyncError.writePermission { throw PlaylistSyncError.writePermission }
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
                    try await client.immutableUpload(client.musicPath(pairing.descriptor.musicFolderId, revision.path), body: body)
                    try db.acknowledgeSyncRevision(id)
                } catch PlaylistSyncError.authentication { throw PlaylistSyncError.authentication }
                catch PlaylistSyncError.writePermission { throw PlaylistSyncError.writePermission }
                catch PlaylistSyncError.integrity { throw PlaylistSyncError.integrity }
                catch { failedPlaylists.insert(revision.playlistId); uploadsFailed += 1 }
            }
            try db.projectSyncRevisions()
            AppCoordinator.shared?.playlistManager.loadPlaylists()
            refreshStatus()
            let conflicts = states.filter { $0.issue == "conflict" }.count
            let incomplete = states.filter { $0.issue == "incomplete" || $0.issue == "invalid" }.count
            status = blocked + pendingErrors + uploadsFailed + conflicts + incomplete + states.filter { $0.intent != nil }.count == 0 ? "Crates synced. Audio availability is shown per crate." :
                "Changes are waiting to sync. Review the affected crate for details."
        } catch { status = safeMessage(error) }
    }
    private func mapLocal(_ id: Int64, snapshotPath: String?, root: URL, pairing: SyncPairing, client: DropboxPlaylistTransport, db: DatabaseManager) async throws -> String {
        guard let path = snapshotPath else { throw PlaylistSyncError.mappingBlocked }
        let local = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard local.path.hasPrefix(prefix) else { throw PlaylistSyncError.mappingBlocked }
        let relative = String(local.path.dropFirst(prefix.count))
        guard !relative.split(separator: "/").contains(".crate-sync") else { throw PlaylistSyncError.mappingBlocked }
        let remote = try await client.metadata(client.musicPath(pairing.descriptor.musicFolderId, relative))
        guard remote.tag == "file", let fileID = remote.id, let expectedHash = remote.content_hash else { throw PlaylistSyncError.mappingBlocked }
        let hash = try await Task.detached(priority: .utility) { try DropboxPlaylistTransport.contentHash(local) }.value
        guard hash == expectedHash else { throw PlaylistSyncError.mappingBlocked }
        try db.saveSyncMapping(fileID: fileID, trackID: id, hash: hash, expectedPath: path)
        return fileID
    }
    private func mapRemote(_ fileID: String, root: URL, pairing: SyncPairing, client: DropboxPlaylistTransport, db: DatabaseManager) async throws {
        try await DropboxPlaylistMapping.refreshRemote(fileID, root: root, remoteRootPath: pairing.remoteRootPath, client: client, db: db)
    }

    func summary(for id: UUID) -> String {
        let state = states.first { $0.localID == id }
        if let recovery { return recovery }
        if isConnected && !isPaired { return "Check music folder" }
        return CrateSyncPresentation.summary(state: state, connected: isConnected && isPaired,
            working: isWorking, queued: state.map { queuedCrates.contains($0.sharedID) } ?? false)
    }

    func openConnectionSettings() {
        NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: NSNotification.Name("SettingsSelectTab"), object: SettingsView.SettingsTab.integrations)
        }
    }

    func chooseMusicFolder() async {
        let alert = NSAlert()
        alert.messageText = "Choose music folder"
        alert.informativeText = "Enter the folder path in Dropbox, then choose its matching local Mac folder. Use / for the Crate App folder."
        let field = NSTextField(string: UserDefaults.standard.string(forKey: "dropboxPlaylistMusicPath").flatMap { $0.isEmpty ? nil : $0 } ?? "/")
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Choose local folder…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(field.stringValue, forKey: "dropboxPlaylistMusicPath")
        await pair(remotePath: field.stringValue)
    }

    func trackLabel(_ member: SyncMember, position: Int) -> String {
        if let id = member.localTrackID, let track = db?.getTracksWithArtwork(byIds: [id]).first {
            return "\(track.title) — \(track.artist)"
        }
        if let path = member.localPath { return URL(fileURLWithPath: path).lastPathComponent }
        return "Unavailable recording at position \(position + 1)"
    }

    func resolve(_ state: SyncPlaylistState) {
        guard !isWorking, let db else { return }
        do {
            guard var current = try db.syncStates().first(where: { $0.localID == state.localID }) else { return }
            let revisions = try db.syncRevisions(current.sharedID)
            let graph = try RevisionGraph(revisions: revisions)
            guard !graph.incomplete else { status = "Waiting for missing revisions. Sync again before reviewing."; return }
            current.heads = graph.heads
            let versions = revisions.filter { current.heads.contains($0.revisionId) }.sorted { $0.revisionId < $1.revisionId }
            guard versions.count > 1 else { refreshStatus(); return }
            // Opening/reviewing/Cancel is read-only, including received-only conflicts.
            let localDevice = try db.dbQueue.read { database in
                try Data.fetchOne(database, sql: "SELECT value FROM playlist_sync_meta WHERE key = 'device'")
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
            let alert = NSAlert()
            alert.messageText = "Changes on both devices"
            alert.informativeText = "Review each name and ordered track list below. Deleted versions remove the crate on both devices; music files remain. Keep both preserves the other live version as a separate crate."
            let ownVersions = versions.filter { $0.deviceId == localDevice }
            let otherVersions = versions.filter { $0.deviceId != localDevice }
            // Restored devices can have conflicts containing no current-device head.
            // Keep all heads reviewable without mislabelling a foreign head as this Mac.
            let macVersions = ownVersions.isEmpty ? versions : ownVersions
            let phoneVersions = otherVersions.isEmpty ? versions : otherVersions
            alert.addButton(withTitle: ownVersions.isEmpty ? "Use selected version" : "Use Mac version")
            alert.addButton(withTitle: otherVersions.isEmpty ? "Use other selected version" : "Use iPhone version")
            alert.addButton(withTitle: "Keep both")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[2].isEnabled = versions.contains { !$0.deleted }
            let mac = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
            let phone = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
            let titles = versions.enumerated().map { index, version in
                "Version \(index + 1): \(version.name) — \(version.deviceId == localDevice ? "Mac (this device)" : "iPhone / other device")\(version.deleted ? " — Deleted" : "")"
            }
            func title(_ version: PlaylistRevision) -> String { titles[versions.firstIndex { $0.revisionId == version.revisionId }!] }
            mac.addItems(withTitles: macVersions.map(title)); phone.addItems(withTitles: phoneVersions.map(title))
            if ownVersions.isEmpty || otherVersions.isEmpty { phone.selectItem(at: min(1, phoneVersions.count - 1)) }
            var previews: [String] = []
            for (index, version) in versions.enumerated() {
                var lines = [titles[index], "Name: \(version.name)", version.deleted ? "Crate deleted" : "Ordered tracks:"]
                for (position, ref) in version.tracks.enumerated() {
                    let id = try db.syncMapping(fileID: ref.fileId)
                    lines.append("\(position + 1). " + trackLabel(SyncMember(fileId: ref.fileId, localTrackID: id), position: position))
                }
                let differences = versions.filter { $0.revisionId != version.revisionId }.map { other in
                    let added = Set(version.tracks.map(\.fileId)).subtracting(other.tracks.map(\.fileId)).count
                    let removed = Set(other.tracks.map(\.fileId)).subtracting(version.tracks.map(\.fileId)).count
                    let order = version.tracks.map(\.fileId) != other.tracks.map(\.fileId)
                    return "Compared with \(other.name): \(added) added, \(removed) removed; \(order ? "order/membership differs" : "same order"); \(version.name == other.name ? "same name" : "name differs"); \(version.deleted == other.deleted ? "same deletion state" : "delete versus edit")."
                }
                previews.append((lines + differences).joined(separator: "\n"))
            }
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
            text.string = previews.joined(separator: "\n\n")
            text.isEditable = false; text.isSelectable = true
            text.font = .systemFont(ofSize: 12)
            text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
            scroll.hasVerticalScroller = true; scroll.documentView = text
            let stack = NSStackView(views: [scroll, NSTextField(labelWithString: ownVersions.isEmpty ? "Version to keep:" : "Mac choice:"), mac,
                NSTextField(labelWithString: otherVersions.isEmpty ? "Other version:" : "iPhone / other device choice:"), phone])
            stack.orientation = .vertical; stack.alignment = .leading
            alert.accessoryView = stack
            let commit: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self, (1000...1002).contains(response.rawValue) else { return }
                do {
                    let macVersion = macVersions[mac.indexOfSelectedItem], phoneVersion = phoneVersions[phone.indexOfSelectedItem]
                    var selected = response == .alertSecondButtonReturn ? phoneVersion : macVersion
                    var copy: String?
                    if response == .alertThirdButtonReturn {
                        guard macVersion.revisionId != phoneVersion.revisionId else {
                            self.status = "Choose two different versions for Keep both."
                            return
                        }
                        guard !macVersion.deleted || !phoneVersion.deleted else {
                            self.status = "Both selected versions delete the crate. Choose a live version to keep both."
                            return
                        }
                        if phoneVersion.deleted { selected = phoneVersion; copy = macVersion.deleted ? nil : macVersion.revisionId }
                        else { copy = phoneVersion.revisionId }
                    }
                    try db.resolveSyncConflict(localID: current.localID, chosen: selected.revisionId, expectedHeads: current.heads, keepBoth: copy)
                    AppCoordinator.shared?.playlistManager.loadPlaylists()
                    self.status = "Conflict resolution queued."; self.scheduleSync()
                } catch PlaylistSyncError.staleEditor {
                    self.status = "Changes arrived while reviewing. Review the refreshed versions."
                    self.refreshStatus()
                    if let fresh = self.states.first(where: { $0.localID == current.localID }) { self.resolve(fresh) }
                } catch { self.status = self.safeMessage(error) }
                self.refreshStatus()
            }
            if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: commit) }
            else { commit(alert.runModal()) }
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
