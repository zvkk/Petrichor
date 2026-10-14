import Foundation
import GRDB

/// Verifies exact relative paths and Dropbox content hashes; never matches by title or basename.
enum DropboxPlaylistMapping {
    private enum LocalPublicationFailure: Error { case blocked }
    static func refreshRemote(_ fileID: String, root: URL, remoteRootPath: String,
                              client: DropboxPlaylistTransport, db: DatabaseManager,
                              scope: any PublicationScopeAccess = SecurityScopedPublicationAccess()) async throws {
        do {
            let remote = try await client.metadata(fileID)
            guard remote.tag == "file", remote.id == fileID, let path = remote.path_display,
                  let expectedHash = remote.content_hash else { throw PlaylistSyncError.mappingBlocked }
            let prefix = DropboxPlaylistTransport.childPath(remoteRootPath, "")
            guard path.lowercased().hasPrefix(prefix.lowercased()) else { throw PlaylistSyncError.mappingBlocked }
            let publications = try db.publicationRecords(fileID: fileID)
            if !publications.isEmpty {
                let source = PublicationSource(manager: db, snapshotDirectory: FileManager.default.temporaryDirectory, scope: scope)
                var blocked = false
                var validations: [PublicationValidation] = []
                for record in publications {
                    guard path.lowercased() == DropboxPlaylistTransport.childPath(remoteRootPath, record.destination).lowercased(),
                          expectedHash == record.verifiedMapping?.contentHash,
                          remote.size == record.snapshot.sourceIdentity?.size else { throw PlaylistSyncError.mappingBlocked }
                    do {
                        validations.append(try await Task.detached(priority: .utility) { try source.validatePublication(record) }.value)
                    }
                    catch { try db.blockPublication(record); blocked = true }
                }
                try db.restorePublicationMappings(validations)
                if blocked { throw LocalPublicationFailure.blocked }
                return
            }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.split(separator: "/").contains(where: { $0.lowercased() == ".crate-sync" }) else { throw PlaylistSyncError.mappingBlocked }
            let local = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            guard local.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { throw PlaylistSyncError.mappingBlocked }
            guard let id = try await db.dbQueue.read({ try Int64.fetchOne($0, sql: "SELECT id FROM tracks WHERE path = ?", arguments: [local.path]) }) else { throw PlaylistSyncError.mappingBlocked }
            let hash: String
            do { hash = try await Task.detached(priority: .utility) { try DropboxPlaylistTransport.contentHash(local) }.value }
            catch { throw PlaylistSyncError.mappingBlocked }
            guard hash == expectedHash else { throw PlaylistSyncError.mappingBlocked }
            try db.saveSyncMapping(fileID: fileID, trackID: id, hash: hash, expectedPath: local.path)
        } catch LocalPublicationFailure.blocked {
            throw PlaylistSyncError.mappingBlocked
        } catch PlaylistSyncError.mappingBlocked {
            try db.invalidateSyncMapping(fileID)
            throw PlaylistSyncError.mappingBlocked
        } catch DropboxRequestError.notFound {
            try db.invalidateSyncMapping(fileID)
            throw PlaylistSyncError.mappingBlocked
        }
    }
}

extension DatabaseManager {
    /// Only an exact remote refresh plus scoped byte receipts can restore a remotely blocked binding.
    fileprivate func restorePublicationMappings(_ validations: [PublicationValidation]) throws {
        try dbQueue.write { db in
            var unblocked = false
            for validation in validations {
                let record = validation.record
                guard record.state == .completed else { throw PlaylistSyncError.mappingBlocked }
                try validation.consume(db)
                let key = "publication-blocked:\(record.id.uuidString)"
                if try Data.fetchOne(db, sql: "SELECT value FROM playlist_sync_meta WHERE key=?", arguments: [key]) != nil { unblocked = true }
                try Self.savePublicationMapping(record, in: db)
            }
            if unblocked {
                db.afterNextTransaction { _ in NotificationCenter.default.post(name: .playlistSyncLocalEdit, object: nil) }
            }
        }
    }
}
