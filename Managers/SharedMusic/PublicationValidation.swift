import Foundation
import GRDB
import Darwin

/// A single-use, scoped receipt of off-thread byte verification. Never persisted or caller-constructed.
final class PublicationValidation {
    let record: Publication
    private let leases: [PublicationScopeLease]
    private let sourceFolder: String
    private let lock = NSLock()
    private var consumed = false
    fileprivate init(record: Publication, leases: [PublicationScopeLease], sourceFolder: String) {
        self.record = record; self.leases = leases; self.sourceFolder = sourceFolder
    }
    func consume(_ db: Database, allowingCancellation: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard !consumed else { throw PlaylistSyncError.mappingBlocked }
        consumed = true
        guard let current = try PublicationJournal.record(record.id, in: db) else { throw PlaylistSyncError.mappingBlocked }
        let cancelled = allowingCancellation && current.state == .cancelled && current.generation == record.generation + 1
            && current.snapshot == record.snapshot && current.destination == record.destination
        guard current == record || cancelled,
              let row = try Row.fetchOne(db, sql: "SELECT t.path, f.path AS folder, f.bookmark_data FROM tracks t JOIN folders f ON f.id=t.folder_id WHERE t.id=?", arguments: [record.trackID]),
              row["path"] as String == record.snapshot.sourcePath,
              row["folder"] as String == sourceFolder,
              row["bookmark_data"] as Data == record.snapshot.sourceBookmark,
              let pairing = try Data.fetchOne(db, sql: "SELECT value FROM playlist_sync_meta WHERE key='pairing'"),
              try JSONDecoder().decode(SyncPairing.self, from: pairing) == record.snapshot.pairing else { throw PlaylistSyncError.mappingBlocked }
        try withExtendedLifetime(leases) {
            for (folder, relative, expected) in [
                (sourceFolder, String(record.snapshot.sourcePath.dropFirst(sourceFolder.hasSuffix("/") ? sourceFolder.count : sourceFolder.count + 1)), record.snapshot.sourceIdentity),
                (record.snapshot.pairing.localRootPath, record.destination, record.snapshot.pairedIdentity)
            ] {
                let root = try PublicationSource.openDirectory(folder)
                defer { close(root) }
                let fd = try PublicationSource.openRelative(relative, root: root)
                defer { close(fd) }
                guard try PublicationSource.identity(fd) == expected else { throw PlaylistSyncError.mappingBlocked }
            }
        }
    }
}
extension PublicationSource {
    /// Caller runs this on a utility task, outside SQL and the UI actor.
    func validatePublication(_ record: Publication) throws -> PublicationValidation {
        let selected = try selectedSource(record.trackID)
        let leases = [try scope.access(bookmark: selected.bookmark, expectedPath: selected.folder),
                      try scope.access(bookmark: record.snapshot.pairing.localRootBookmark, expectedPath: record.snapshot.pairing.localRootPath)]
        try withExtendedLifetime(leases) { try verifySourceAndCopy(record) }
        return PublicationValidation(record: record, leases: leases, sourceFolder: selected.folder)
    }
}
