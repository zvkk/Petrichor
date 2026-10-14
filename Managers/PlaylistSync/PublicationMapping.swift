import Foundation
import GRDB

extension DatabaseManager {
    static func publicationRecords(_ db: Database) throws -> [Publication] {
        try String.fetchAll(db, sql: "SELECT id FROM shared_music_publication WHERE state='completed' ORDER BY rowid DESC").compactMap {
            guard let id = UUID(uuidString: $0) else { throw PublicationError.integrity }
            return try PublicationJournal.record(id, in: db)
        }
    }
    /// Each physical original owns its proof. One remote ID may have several independent originals.
    static func publicationBindings(_ db: Database, member: SyncMember, resolved: [Int64: String] = [:], records supplied: [Publication]? = nil) throws -> [Publication] {
        let records = try supplied ?? publicationRecords(db)
        let localPath = try member.localTrackID.flatMap { try String.fetchOne(db, sql: "SELECT path FROM tracks WHERE id=?", arguments: [$0]) }
        if let original = records.first(where: { $0.trackID == member.localTrackID }) { return [original] }
        if let copy = records.first(where: { localPath == URL(fileURLWithPath: $0.snapshot.pairing.localRootPath).appendingPathComponent($0.destination).path }) { return [copy] }
        let fileID = member.fileId ?? member.localTrackID.flatMap { resolved[$0] }
        // Unknown local projections of a publication-owned remote ref must still prove their original.
        var originals = Set<Int64>()
        return records.filter { $0.verifiedMapping?.fileID == fileID && originals.insert($0.trackID).inserted }
    }
    static func savePublicationMapping(_ record: Publication, in db: Database) throws {
        guard let proof = record.verifiedMapping else { throw PublicationError.integrity }
        try db.execute(sql: "INSERT OR REPLACE INTO playlist_sync_mapping VALUES (?, ?, ?)", arguments: [proof.fileID, record.trackID, proof.contentHash])
        try db.execute(sql: "DELETE FROM playlist_sync_meta WHERE key=?", arguments: ["publication-blocked:\(record.id.uuidString)"])
        // Existing physical memberships are never reprojected. Resolve the selected original at materialization.
    }
    func publicationRecords(fileID: String) throws -> [Publication] {
        try dbQueue.read { db in
            var originals = Set<Int64>()
            return try Self.publicationRecords(db).filter { $0.verifiedMapping?.fileID == fileID && originals.insert($0.trackID).inserted }
        }
    }
    func blockPublication(_ record: Publication) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO playlist_sync_meta VALUES (?, ?)", arguments: ["publication-blocked:\(record.id.uuidString)", Data(record.id.uuidString.utf8)])
        }
    }
    func publicationFileID(trackID: Int64) throws -> String? {
        try dbQueue.read { db in
            try Self.publicationBindings(db, member: SyncMember(fileId: nil, localTrackID: trackID)).first?.verifiedMapping?.fileID
        }
    }
    /// All expensive verification happens before entering materializeSyncIntent's SQL transaction.
    func validatePublicationIntent(_ id: UUID, generation: Int64, resolved: [Int64: String],
                                   scope: any PublicationScopeAccess = SecurityScopedPublicationAccess()) async throws -> [PublicationValidation] {
        let records = try await dbQueue.read { db -> [Publication] in
            guard let intent = try self.syncState(db, localID: id)?.intent, intent.generation == generation else { throw PlaylistSyncError.mappingBlocked }
            var seen = Set<UUID>()
            let records = try Self.publicationRecords(db)
            return try intent.members.flatMap { try Self.publicationBindings(db, member: $0, resolved: resolved, records: records) }.filter { seen.insert($0.id).inserted }
        }
        let source = PublicationSource(manager: self, snapshotDirectory: FileManager.default.temporaryDirectory, scope: scope)
        var validations: [PublicationValidation] = []
        for record in records {
            do {
                let validation = try await Task.detached(priority: .utility) { try source.validatePublication(record) }.value
                validations.append(validation)
            } catch {
                try blockPublication(record)
                throw PlaylistSyncError.mappingBlocked
            }
        }
        return validations
    }
    static func validatePublicationMembers(_ db: Database, members: [SyncMember], resolved: [Int64: String], validations: [PublicationValidation]) throws {
        var required: [UUID: Publication] = [:]
        let records = try publicationRecords(db)
        for member in members {
            for record in try publicationBindings(db, member: member, resolved: resolved, records: records) {
                required[record.id] = record
                guard try Data.fetchOne(db, sql: "SELECT value FROM playlist_sync_meta WHERE key=?", arguments: ["publication-blocked:\(record.id.uuidString)"]) == nil,
                      let proof = record.verifiedMapping,
                      (member.fileId ?? member.localTrackID.flatMap { resolved[$0] }) == proof.fileID else { throw PlaylistSyncError.mappingBlocked }
            }
        }
        for (id, record) in required {
            guard let receipt = validations.first(where: { $0.record.id == id }), receipt.record == record else { throw PlaylistSyncError.mappingBlocked }
            try receipt.consume(db)
        }
    }
}
