import Foundation
import GRDB

/// Verifies exact relative paths and Dropbox content hashes; never matches by title or basename.
enum DropboxPlaylistMapping {
    static func refreshRemote(_ fileID: String, root: URL, remoteRootPath: String,
                              client: DropboxPlaylistTransport, db: DatabaseManager) async throws {
        do {
            let remote = try await client.metadata(fileID)
            guard remote.tag == "file", remote.id == fileID, let path = remote.path_display,
                  let expectedHash = remote.content_hash else { throw PlaylistSyncError.mappingBlocked }
            let prefix = DropboxPlaylistTransport.childPath(remoteRootPath, "")
            guard path.lowercased().hasPrefix(prefix.lowercased()) else { throw PlaylistSyncError.mappingBlocked }
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
        } catch PlaylistSyncError.mappingBlocked {
            try db.invalidateSyncMapping(fileID)
            throw PlaylistSyncError.mappingBlocked
        } catch DropboxRequestError.notFound {
            try db.invalidateSyncMapping(fileID)
            throw PlaylistSyncError.mappingBlocked
        }
    }
}
