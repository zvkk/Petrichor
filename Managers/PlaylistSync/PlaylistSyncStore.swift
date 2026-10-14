import Foundation
import GRDB

extension Notification.Name { static let playlistSyncLocalEdit = Notification.Name("playlistSyncLocalEdit") }
struct SyncPlaylistState {
    var localID: UUID
    var sharedID: String
    var generation: Int64
    var heads: [String]
    var members: [SyncMember]
    var intent: SyncIntent?
    var appliedHead: String?
    var issue: String?
}
extension DatabaseManager {
    static func createPlaylistSyncSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE playlist_sync_meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            CREATE TABLE playlist_sync_state (local_id TEXT PRIMARY KEY, shared_id TEXT UNIQUE NOT NULL,
              generation INTEGER NOT NULL DEFAULT 0, heads BLOB NOT NULL, members BLOB NOT NULL,
              intent BLOB, applied_head TEXT, issue TEXT);
            CREATE TABLE playlist_sync_mapping (file_id TEXT PRIMARY KEY, track_id INTEGER NOT NULL, content_hash TEXT NOT NULL);
            CREATE TABLE playlist_sync_revision (revision_id TEXT PRIMARY KEY, playlist_id TEXT NOT NULL, body BLOB NOT NULL);
            CREATE INDEX playlist_sync_revision_playlist ON playlist_sync_revision(playlist_id);
            CREATE TABLE playlist_sync_outbox (revision_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL);
            CREATE TABLE playlist_sync_incoming (path TEXT PRIMARY KEY, error TEXT);
            """)
    }
    private func syncEncode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    func syncState(_ db: Database, localID: UUID) throws -> SyncPlaylistState? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM playlist_sync_state WHERE local_id = ?", arguments: [localID.uuidString]) else { return nil }
        return try syncState(row)
    }
    private func syncState(_ row: Row) throws -> SyncPlaylistState {
        let decoder = JSONDecoder()
        let intentData: Data? = row["intent"]
        return SyncPlaylistState(localID: UUID(uuidString: row["local_id"])!, sharedID: row["shared_id"],
            generation: row["generation"], heads: try decoder.decode([String].self, from: row["heads"]),
            members: try decoder.decode([SyncMember].self, from: row["members"]),
            intent: try intentData.map { try decoder.decode(SyncIntent.self, from: $0) },
            appliedHead: row["applied_head"], issue: row["issue"])
    }
    func syncStates() throws -> [SyncPlaylistState] {
        try dbQueue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM playlist_sync_state").map(self.syncState) }
    }
    func syncIntent(_ id: UUID) throws -> SyncIntent? { try dbQueue.read { try self.syncState($0, localID: id)?.intent } }
    func syncPairing() throws -> SyncPairing? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM playlist_sync_meta WHERE key = 'pairing'").map { try JSONDecoder().decode(SyncPairing.self, from: $0) }
        }
    }
    func saveSyncPairing(_ pairing: SyncPairing) throws {
        try pairing.descriptor.validate()
        try dbQueue.write { db in
            if let old = try Data.fetchOne(db, sql: "SELECT value FROM playlist_sync_meta WHERE key = 'pairing'") {
                let existing = try JSONDecoder().decode(SyncPairing.self, from: old)
                guard existing.descriptor == pairing.descriptor, existing.localRootPath == pairing.localRootPath else {
                    throw PlaylistSyncError.pairingChanged
                }
            }
            try db.execute(sql: "INSERT OR REPLACE INTO playlist_sync_meta VALUES ('pairing', ?)", arguments: [try self.syncEncode(pairing)])
        }
    }
    func syncDeviceID(_ db: Database) throws -> String {
        if let data = try Data.fetchOne(db, sql: "SELECT value FROM playlist_sync_meta WHERE key = 'device'"), let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString.lowercased()
        try db.execute(sql: "INSERT INTO playlist_sync_meta VALUES ('device', ?)", arguments: [Data(id.utf8)])
        return id
    }
    func sharePlaylist(_ id: UUID) throws {
        try dbQueue.write { db in
            guard let playlist = try Playlist.fetchOne(db, key: id.uuidString), playlist.type == .regular,
                  playlist.isUserEditable, playlist.isContentEditable else { throw PlaylistSyncError.configuration }
            if try self.syncState(db, localID: id) != nil { return }
            try db.execute(sql: "INSERT INTO playlist_sync_state(local_id, shared_id, heads, members) VALUES (?, ?, ?, ?)",
                arguments: [id.uuidString, UUID().uuidString.lowercased(), try self.syncEncode([String]()), try self.syncEncode([SyncMember]())])
            try self.capturePlaylistIntent(db, playlistID: id, mutation: .append)
        }
    }
    /// Called only by user mutation transactions, never a scan/provider observer.
    func capturePlaylistIntent(_ db: Database, playlistID: UUID, mutation: PlaylistSyncMutation) throws {
        guard var state = try syncState(db, localID: playlistID) else { return }
        if state.issue == "conflict" { throw PlaylistSyncError.conflict }
        let playlist = try Playlist.fetchOne(db, key: playlistID.uuidString)
        let ids = try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == playlistID.uuidString)
            .order(PlaylistTrack.Columns.position).fetchAll(db).map(\.trackId)
        var members = state.intent?.members ?? state.members
        var deleted = false
        switch mutation {
        case .metadata: break
        case .append:
            let existing = Set(members.compactMap(\.localTrackID))
            members.append(contentsOf: ids.filter { !existing.contains($0) }.map { SyncMember(fileId: nil, localTrackID: $0) })
        case .remove(let removed): members = members.filter { !($0.localTrackID.map(removed.contains) ?? false) }
        case .order: members = SyncMember.projectEdit(members, orderedIDs: ids, removedIDs: [])
        case .replace(let removed): members = SyncMember.projectEdit(members, orderedIDs: ids, removedIDs: removed)
        case .delete: members = []; deleted = true
        }
        for index in members.indices where members[index].fileId == nil && members[index].localPath == nil {
            if let id = members[index].localTrackID {
                members[index].localPath = try String.fetchOne(db, sql: "SELECT path FROM tracks WHERE id = ?", arguments: [id])
            }
        }
        state.generation += 1
        let name = playlist?.name ?? state.intent?.name ?? "Deleted Playlist"
        guard PlaylistRevision.clean(name, max: 255), name == name.trimmingCharacters(in: PlaylistRevision.nameTrimSet), members.count <= 10000 else { throw PlaylistSyncError.invalidRevision }
        let intent = SyncIntent(generation: state.generation, name: name, deleted: deleted, members: members,
            parents: state.intent?.parents ?? state.heads)
        try db.execute(sql: "UPDATE playlist_sync_state SET generation = ?, members = ?, intent = ?, issue = NULL WHERE local_id = ?",
            arguments: [state.generation, try syncEncode(members), try syncEncode(intent), playlistID.uuidString])
        db.afterNextTransaction { _ in NotificationCenter.default.post(name: .playlistSyncLocalEdit, object: nil) }
    }
    func playlistEditorSnapshot(_ id: UUID) throws -> PlaylistEditorSnapshot {
        try dbQueue.read { try self.editorSnapshot($0, id: id) }
    }
    private func editorSnapshot(_ db: Database, id: UUID) throws -> PlaylistEditorSnapshot {
        guard let playlist = try Playlist.fetchOne(db, key: id.uuidString) else { throw PlaylistSyncError.staleEditor }
        return PlaylistEditorSnapshot(name: playlist.name,
            trackIDs: try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == id.uuidString).order(PlaylistTrack.Columns.position).fetchAll(db).map(\.trackId),
            generation: try syncState(db, localID: id)?.generation ?? 0)
    }
    func savePlaylistEditor(playlistID: UUID, name: String, tracks: [Track], expected: PlaylistEditorSnapshot) async throws {
        try await dbQueue.write { db in
            guard try self.editorSnapshot(db, id: playlistID) == expected else { throw PlaylistSyncError.staleEditor }
            guard var playlist = try Playlist.fetchOne(db, key: playlistID.uuidString), playlist.type == .regular,
                  playlist.isUserEditable, playlist.isContentEditable else { throw PlaylistSyncError.configuration }
            playlist.name = name
            playlist.dateModified = Date()
            try playlist.update(db, columns: [Playlist.Columns.name, Playlist.Columns.dateModified])
            try Self.updatePinnedPlaylistName(playlistID: playlistID.uuidString, name: name, in: db)
            let ids = tracks.compactMap(\.trackId)
            guard Set(ids).count == ids.count else { throw PlaylistSyncError.configuration }
            try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == playlistID.uuidString).deleteAll(db)
            for (position, id) in ids.enumerated() {
                try PlaylistTrack(playlistId: playlistID.uuidString, trackId: id, position: position, dateAdded: Date().addingTimeInterval(Double(position))).insert(db)
            }
            let removed = Set(expected.trackIDs).subtracting(ids)
            let retainedOrder = expected.trackIDs.filter { !removed.contains($0) }
            let appendedIDs = ids.filter { !expected.trackIDs.contains($0) }
            if ids == expected.trackIDs {
                try self.capturePlaylistIntent(db, playlistID: playlistID, mutation: .metadata)
            } else if ids == retainedOrder + appendedIDs {
                if !removed.isEmpty { try self.capturePlaylistIntent(db, playlistID: playlistID, mutation: .remove(removed)) }
                try self.capturePlaylistIntent(db, playlistID: playlistID, mutation: .append)
            } else {
                try self.capturePlaylistIntent(db, playlistID: playlistID, mutation: .replace(removed))
            }
        }
    }
    func saveSyncMapping(fileID: String, trackID: Int64, hash: String, expectedPath: String? = nil) throws {
        try dbQueue.write { db in
            if let expectedPath {
                let currentPath = try String.fetchOne(db, sql: "SELECT path FROM tracks WHERE id = ?", arguments: [trackID])
                guard currentPath == expectedPath else { throw PlaylistSyncError.mappingBlocked }
            }
            let previous = try Int64.fetchOne(db, sql: "SELECT track_id FROM playlist_sync_mapping WHERE file_id = ?", arguments: [fileID])
            let previousHash = try String.fetchOne(db, sql: "SELECT content_hash FROM playlist_sync_mapping WHERE file_id = ?", arguments: [fileID])
            try db.execute(sql: "INSERT OR REPLACE INTO playlist_sync_mapping VALUES (?, ?, ?)", arguments: [fileID, trackID, hash])
            if previous != trackID || previousHash != hash {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM playlist_sync_state") {
                    var state = try self.syncState(row)
                    guard state.members.contains(where: { $0.fileId == fileID }) else { continue }
                    state.generation += 1
                    for index in state.members.indices where state.members[index].fileId == fileID { state.members[index].localTrackID = trackID }
                    if var intent = state.intent {
                        intent.generation = state.generation
                        for index in intent.members.indices where intent.members[index].fileId == fileID { intent.members[index].localTrackID = trackID }
                        state.intent = intent
                    }
                    try db.execute(sql: "UPDATE playlist_sync_state SET generation = ?, members = ?, intent = ?, applied_head = NULL WHERE local_id = ?",
                        arguments: [state.generation, try self.syncEncode(state.members), try state.intent.map(self.syncEncode), state.localID.uuidString])
                    try self.projectSyncMembersOnly(db, state: state)
                }
            }
        }
    }
    /// Definitively unavailable/mismatched audio invalidates only native projection, never wire membership.
    func invalidateSyncMapping(_ fileID: String) throws {
        try dbQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_sync_mapping WHERE file_id = ?", arguments: [fileID]) ?? 0
            guard count > 0 else { return }
            try db.execute(sql: "DELETE FROM playlist_sync_mapping WHERE file_id = ?", arguments: [fileID])
            for row in try Row.fetchAll(db, sql: "SELECT * FROM playlist_sync_state") {
                var state = try self.syncState(row)
                guard state.members.contains(where: { $0.fileId == fileID }) else { continue }
                state.generation += 1
                for index in state.members.indices where state.members[index].fileId == fileID { state.members[index].localTrackID = nil }
                if var intent = state.intent {
                    intent.generation = state.generation
                    for index in intent.members.indices where intent.members[index].fileId == fileID { intent.members[index].localTrackID = nil }
                    state.intent = intent
                }
                try db.execute(sql: "UPDATE playlist_sync_state SET generation = ?, members = ?, intent = ?, applied_head = NULL WHERE local_id = ?",
                    arguments: [state.generation, try self.syncEncode(state.members), try state.intent.map(self.syncEncode), state.localID.uuidString])
                try self.projectSyncMembersOnly(db, state: state)
            }
        }
    }
    /// Mapping/source maintenance can update native rows even while a user intent is pending.
    /// It never applies an incoming name/tombstone, changes wire refs, or creates an outbox.
    private func projectSyncMembersOnly(_ db: Database, state: SyncPlaylistState) throws {
        guard try Playlist.fetchOne(db, key: state.localID.uuidString) != nil else { return }
        let previous = try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == state.localID.uuidString).fetchAll(db)
        let dates = Dictionary(previous.map { ($0.trackId, $0.dateAdded) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int64>(), ids: [Int64] = []
        for member in state.members {
            if let id = member.localTrackID, seen.insert(id).inserted, try Track.fetchOne(db, key: id) != nil { ids.append(id) }
        }
        guard previous.sorted(by: { $0.position < $1.position }).map(\.trackId) != ids else { return }
        try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == state.localID.uuidString).deleteAll(db)
        for (position, id) in ids.enumerated() {
            try PlaylistTrack(playlistId: state.localID.uuidString, trackId: id, position: position, dateAdded: dates[id] ?? Date().addingTimeInterval(Double(position))).insert(db)
        }
    }
    func syncMapping(fileID: String) throws -> Int64? {
        try dbQueue.read { try Int64.fetchOne($0, sql: "SELECT track_id FROM playlist_sync_mapping WHERE file_id = ?", arguments: [fileID]) }
    }
    func materializeSyncIntent(_ id: UUID, generation: Int64, resolved: [Int64: String]) throws -> Bool {
        try dbQueue.write { db in
            guard let state = try self.syncState(db, localID: id), let intent = state.intent, intent.generation == generation else { return false }
            guard let pairingData = try Data.fetchOne(db, sql: "SELECT value FROM playlist_sync_meta WHERE key = 'pairing'") else { throw PlaylistSyncError.notPaired }
            let pairing = try JSONDecoder().decode(SyncPairing.self, from: pairingData)
            let members = try intent.members.map { member -> SyncMember in
                if member.fileId != nil { return member }
                guard let local = member.localTrackID, let remote = resolved[local] else { throw PlaylistSyncError.mappingBlocked }
                return SyncMember(fileId: remote, localTrackID: local)
            }
            let refs = members.compactMap(\.fileId)
            guard Set(refs).count == refs.count else { throw PlaylistSyncError.mappingBlocked }
            let device = try self.syncDeviceID(db)
            let final = try self.publishSyncContent(db, library: pairing.descriptor.libraryId, shared: state.sharedID,
                device: device, parents: intent.parents, name: intent.name, deleted: intent.deleted, refs: refs)
            try db.execute(sql: "UPDATE playlist_sync_state SET intent = NULL, members = ?, heads = ?, issue = NULL WHERE local_id = ? AND generation = ?",
                arguments: [try self.syncEncode(members), try self.syncEncode([final]), id.uuidString, generation])
            return true
        }
    }
    /// Bounded parent chain covers arbitrarily many heads, atomically enqueued parent-first.
    private func publishSyncContent(_ db: Database, library: String, shared: String, device: String,
                                    parents: [String], name: String, deleted: Bool, refs: [String]) throws -> String {
        var remaining = parents.sorted(), previous: String?
        repeat {
            let capacity = previous == nil ? 32 : 31
            var batch = Array(remaining.prefix(capacity))
            remaining.removeFirst(batch.count)
            if let previous { batch.append(previous) }
            let revision = PlaylistRevision(protocolVersion: 1, libraryId: library, playlistId: shared,
                revisionId: UUID().uuidString.lowercased(), parentRevisionIds: batch.sorted(), deviceId: device,
                name: name, deleted: deleted, tracks: refs.map { DropboxTrackReference(fileId: $0) })
            try revision.validate()
            let body = try self.syncEncode(revision)
            guard body.count <= 2 * 1024 * 1024 else { throw PlaylistSyncError.invalidRevision }
            try db.execute(sql: "INSERT INTO playlist_sync_revision VALUES (?, ?, ?)", arguments: [revision.revisionId, shared, body])
            let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM playlist_sync_outbox") ?? 0) + 1
            try db.execute(sql: "INSERT INTO playlist_sync_outbox VALUES (?, ?)", arguments: [revision.revisionId, sequence])
            previous = revision.revisionId
        } while !remaining.isEmpty
        return previous!
    }
    func syncOutbox() throws -> [(String, Data)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT r.revision_id, r.body FROM playlist_sync_outbox o JOIN playlist_sync_revision r USING(revision_id) ORDER BY o.sequence")
                .map { ($0["revision_id"], $0["body"]) }
        }
    }
    func acknowledgeSyncRevision(_ id: String) throws {
        try dbQueue.write { try $0.execute(sql: "DELETE FROM playlist_sync_outbox WHERE revision_id = ?", arguments: [id]) }
    }
    func syncCursor() throws -> String? {
        try dbQueue.read { try Data.fetchOne($0, sql: "SELECT value FROM playlist_sync_meta WHERE key = 'cursor'").flatMap { String(data: $0, encoding: .utf8) } }
    }
    func saveSyncDiscovery(paths: [String], cursor: String) throws {
        try dbQueue.write { db in
            for path in paths { try db.execute(sql: "INSERT OR IGNORE INTO playlist_sync_incoming(path) VALUES (?)", arguments: [path]) }
            try db.execute(sql: "INSERT OR REPLACE INTO playlist_sync_meta VALUES ('cursor', ?)", arguments: [Data(cursor.utf8)])
        }
    }
    func resetSyncCursor() throws { try dbQueue.write { try $0.execute(sql: "DELETE FROM playlist_sync_meta WHERE key = 'cursor'") } }
    func syncIncomingPaths() throws -> [String] {
        try dbQueue.read { try String.fetchAll($0, sql: "SELECT path FROM playlist_sync_incoming ORDER BY path") }
    }
    func failSyncIncoming(_ path: String, error: String) throws {
        try dbQueue.write { try $0.execute(sql: "UPDATE playlist_sync_incoming SET error = ? WHERE path = ?", arguments: [error, path]) }
    }
    func receiveSyncRevision(_ body: Data, path: String, library: String) throws {
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 5, Array(components.prefix(3)) == [".crate-sync", "v1", "playlists"], let filename = components.last, filename.hasSuffix(".json") else { throw PlaylistSyncError.invalidRevision }
        let revision = try PlaylistRevision.decode(body, library: library, playlist: components[components.count - 2], revision: String(filename.dropLast(5)))
        try dbQueue.write { db in
            if let existing = try Data.fetchOne(db, sql: "SELECT body FROM playlist_sync_revision WHERE revision_id = ?", arguments: [revision.revisionId]) {
                guard existing == body else { throw PlaylistSyncError.integrity }
            } else {
                try db.execute(sql: "INSERT INTO playlist_sync_revision VALUES (?, ?, ?)", arguments: [revision.revisionId, revision.playlistId, body])
            }
            try db.execute(sql: "DELETE FROM playlist_sync_incoming WHERE path = ?", arguments: [path])
        }
    }
    func syncRevisions(_ shared: String) throws -> [PlaylistRevision] {
        try dbQueue.read { try self.syncRevisions($0, shared: shared) }
    }
    private func syncRevisions(_ db: Database, shared: String) throws -> [PlaylistRevision] {
        try Data.fetchAll(db, sql: "SELECT body FROM playlist_sync_revision WHERE playlist_id = ?", arguments: [shared]).map { try PlaylistRevision.decode($0) }
    }
    func projectSyncRevisions() throws {
        let sharedIDs = try dbQueue.read { try String.fetchAll($0, sql: "SELECT DISTINCT playlist_id FROM playlist_sync_revision") }
        for shared in sharedIDs {
            do {
                try dbQueue.write { db in
                let revisions = try self.syncRevisions(db, shared: shared)
                let graph = try RevisionGraph(revisions: revisions)
                var state = try Row.fetchOne(db, sql: "SELECT * FROM playlist_sync_state WHERE shared_id = ?", arguments: [shared]).map(self.syncState)
                // Pending native intent must materialize before any remote projection.
                if state?.intent != nil { return }
                if state == nil {
                    // A coincidentally equal local UUID does not establish a shared identity.
                    let id = UUID()
                    try db.execute(sql: "INSERT INTO playlist_sync_state(local_id, shared_id, heads, members) VALUES (?, ?, ?, ?)",
                        arguments: [id.uuidString, shared, try self.syncEncode([String]()), try self.syncEncode([SyncMember]())])
                    state = try self.syncState(db, localID: id)
                }
                let outstanding = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_sync_incoming WHERE path LIKE ?", arguments: ["%/\(shared)/%"] ) ?? 0
                if graph.incomplete || outstanding > 0 {
                    if let state { try db.execute(sql: "UPDATE playlist_sync_state SET issue = 'incomplete' WHERE local_id = ?", arguments: [state.localID.uuidString]) }
                    return
                }
                guard let state else { return }
                if graph.heads.count != 1 {
                    try db.execute(sql: "UPDATE playlist_sync_state SET heads = ?, issue = 'conflict', generation = generation + 1 WHERE local_id = ?",
                        arguments: [try self.syncEncode(graph.heads), state.localID.uuidString])
                    return
                }
                let head = graph.heads[0]
                guard let revision = revisions.first(where: { $0.revisionId == head }) else { return }
                var members: [SyncMember] = []
                for ref in revision.tracks {
                    let local = try Int64.fetchOne(db, sql: "SELECT m.track_id FROM playlist_sync_mapping m JOIN tracks t ON t.id = m.track_id WHERE m.file_id = ?", arguments: [ref.fileId])
                    members.append(SyncMember(fileId: ref.fileId, localTrackID: local))
                }
                let expectedIDs = members.compactMap(\.localTrackID).reduce(into: [Int64]()) { result, id in if !result.contains(id) { result.append(id) } }
                let currentIDs = try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == state.localID.uuidString).order(PlaylistTrack.Columns.position).fetchAll(db).map(\.trackId)
                if state.appliedHead == head && state.members == members && currentIDs == expectedIDs { return }
                if revision.deleted {
                    try Playlist.deleteOne(db, key: state.localID.uuidString)
                    try db.execute(sql: "DELETE FROM pinned_items WHERE playlist_id = ?", arguments: [state.localID.uuidString])
                } else {
                    var playlist = try Playlist.fetchOne(db, key: state.localID.uuidString) ?? Playlist(id: state.localID,
                        name: revision.name, tracks: [], dateCreated: Date(), dateModified: Date(), coverArtworkData: nil,
                        type: .regular, isUserEditable: true, isContentEditable: true, smartCriteria: nil)
                    if try Playlist.fetchOne(db, key: state.localID.uuidString) == nil {
                        playlist.sortOrder = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM playlists") ?? -1) + 1
                    }
                    playlist.name = revision.name
                    playlist.dateModified = Date()
                    try playlist.save(db)
                    try Self.updatePinnedPlaylistName(playlistID: state.localID.uuidString, name: revision.name, in: db)
                    try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == state.localID.uuidString).deleteAll(db)
                    var seen = Set<Int64>()
                    for member in members {
                        if let id = member.localTrackID, seen.insert(id).inserted {
                            try PlaylistTrack(playlistId: state.localID.uuidString, trackId: id, position: seen.count - 1, dateAdded: Date().addingTimeInterval(Double(seen.count))).insert(db)
                        }
                    }
                }
                try db.execute(sql: "UPDATE playlist_sync_state SET generation = generation + 1, heads = ?, members = ?, applied_head = ?, issue = NULL WHERE local_id = ?",
                    arguments: [try self.syncEncode([head]), try self.syncEncode(members), head, state.localID.uuidString])
                }
            } catch {
                try dbQueue.write { db in
                    try db.execute(sql: "INSERT OR IGNORE INTO playlist_sync_state(local_id, shared_id, heads, members, issue) VALUES (?, ?, ?, ?, 'invalid')",
                        arguments: [UUID().uuidString, shared, try self.syncEncode([String]()), try self.syncEncode([SyncMember]())])
                    try db.execute(sql: "UPDATE playlist_sync_state SET issue = 'invalid' WHERE shared_id = ?", arguments: [shared])
                }
            }
        }
    }
    func resolveSyncConflict(localID: UUID, chosen: String, expectedHeads: [String], keepBoth: String? = nil) throws {
        try dbQueue.write { db in
            guard let state = try self.syncState(db, localID: localID), state.intent == nil else { throw PlaylistSyncError.staleEditor }
            let revisions = try self.syncRevisions(db, shared: state.sharedID)
            let graph = try RevisionGraph(revisions: revisions)
            guard !graph.incomplete, graph.heads == expectedHeads.sorted(), graph.heads.contains(chosen),
                  let selected = revisions.first(where: { $0.revisionId == chosen }) else { throw PlaylistSyncError.staleEditor }
            // Validate the entire choice before publishing anything. A stale/non-head copy
            // must never create an extra crate or silently degrade Keep both to Use selected.
            if let keepBoth {
                guard keepBoth != chosen, graph.heads.contains(keepBoth),
                      let other = revisions.first(where: { $0.revisionId == keepBoth }), !other.deleted else {
                    throw PlaylistSyncError.staleEditor
                }
            }
            let device = try self.syncDeviceID(db)
            let final = try self.publishSyncContent(db, library: selected.libraryId, shared: state.sharedID,
                device: device, parents: graph.heads, name: selected.name, deleted: selected.deleted, refs: selected.tracks.map(\.fileId))
            try db.execute(sql: "UPDATE playlist_sync_state SET heads = ?, issue = NULL, generation = generation + 1 WHERE local_id = ?",
                arguments: [try self.syncEncode([final]), localID.uuidString])
            if let keepBoth, let other = revisions.first(where: { $0.revisionId == keepBoth }), !other.deleted {
                let copyShared = UUID().uuidString.lowercased()
                let suffix = " (conflict copy)"
                let copyName = String(String.UnicodeScalarView(other.name.unicodeScalars.prefix(255 - suffix.unicodeScalars.count))) + suffix
                _ = try self.publishSyncContent(db, library: other.libraryId, shared: copyShared, device: device,
                    parents: [], name: copyName, deleted: false, refs: other.tracks.map(\.fileId))
            }
        }
        try projectSyncRevisions()
    }
}
