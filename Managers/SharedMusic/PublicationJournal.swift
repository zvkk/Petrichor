import Foundation
import GRDB

final class PublicationJournal {
    let database: DatabaseQueue
    init(database: DatabaseQueue) { self.database = database }

    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE shared_music_publication (
              id TEXT PRIMARY KEY, track_id INTEGER NOT NULL, generation INTEGER NOT NULL,
              source_snapshot BLOB NOT NULL, destination TEXT NOT NULL, state TEXT NOT NULL,
              upload_session BLOB, verified_mapping BLOB, error TEXT
            )
            """)
    }
    func record(_ id: PublicationID) throws -> Publication? {
        try database.read { try Self.record(id, in: $0) }
    }
    static func record(_ id: PublicationID, in db: Database) throws -> Publication? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM shared_music_publication WHERE id = ?", arguments: [id.uuidString]) else { return nil }
        guard let state = PublicationState(rawValue: row["state"]) else { throw PublicationError.integrity }
        let decoder = JSONDecoder()
        let session: Data? = row["upload_session"], proof: Data? = row["verified_mapping"]
        let error: String? = row["error"]
        return Publication(id: id, trackID: row["track_id"], generation: row["generation"],
                           snapshot: try decoder.decode(PublicationSnapshot.self, from: row["source_snapshot"]),
                           destination: row["destination"], state: state,
                           uploadSession: try session.map { try decoder.decode(PublicationUploadSession.self, from: $0) },
                           verifiedMapping: try proof.map { try decoder.decode(PublicationRemoteProof.self, from: $0) },
                           error: error.flatMap(PublicationError.init(rawValue:)))
    }
    func all() throws -> [Publication] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM shared_music_publication ORDER BY rowid").map {
                guard let id = UUID(uuidString: $0), let record = try Self.record(id, in: db) else { throw PublicationError.integrity }
                return record
            }
        }
    }
    func save(_ record: Publication) throws { try database.write { try Self.save(record, in: $0) } }
    /// Transaction-aware seam for atomic mapping/completion; never opens a nested write.
    static func save(_ record: Publication, in db: Database) throws {
        if record.state != .capturing && record.state != .failed && record.state != .cancelled && !record.snapshot.isReady {
            throw PublicationError.invalidTransition
        }
        if record.state == .completed && record.verifiedMapping == nil { throw PublicationError.invalidTransition }
        if let old = try Self.record(record.id, in: db) {
            guard old.trackID == record.trackID, old.generation == record.generation,
                  old.destination == record.destination,
                  old.snapshot.trackID == record.snapshot.trackID,
                  old.snapshot.sourcePath == record.snapshot.sourcePath,
                  old.snapshot.sourceBookmark == record.snapshot.sourceBookmark,
                  old.snapshot.sourceIdentity == record.snapshot.sourceIdentity,
                  old.snapshot.pairing == record.snapshot.pairing,
                  (!old.snapshot.isReady || old.snapshot == record.snapshot) else { throw PublicationError.integrity }
        }
        if let old = try Self.record(record.id, in: db) {
            if old.state == .completed && record.state != .completed { throw PublicationError.invalidTransition }
            if old.state == .capturing && ![.capturing, .queued, .failed, .cancelled].contains(record.state) {
                throw PublicationError.invalidTransition
            }
        }
        guard record.trackID == record.snapshot.trackID, record.generation > 0 else { throw PublicationError.integrity }
        _ = try PublicationSource.components(record.destination)
        if let session = record.uploadSession {
            guard !session.id.isEmpty, session.id.count <= 1024,
                  session.offset <= UInt64(record.snapshot.sourceIdentity?.size ?? 0) else { throw PublicationError.integrity }
        }
        if let proof = record.verifiedMapping {
            guard proof.fileID.hasPrefix("id:"), proof.contentHash == record.snapshot.dropboxHash,
                  proof.size == UInt64(record.snapshot.sourceIdentity?.size ?? 0) else { throw PublicationError.integrity }
        }
        let encoder = JSONEncoder()
        try db.execute(sql: """
            INSERT INTO shared_music_publication VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET source_snapshot=excluded.source_snapshot, state=excluded.state,
            upload_session=excluded.upload_session, verified_mapping=excluded.verified_mapping, error=excluded.error
            """, arguments: [record.id.uuidString, record.trackID, record.generation, try encoder.encode(record.snapshot),
                              record.destination, record.state.rawValue, try record.uploadSession.map(encoder.encode),
                              try record.verifiedMapping.map(encoder.encode), record.error?.rawValue])
    }
    /// Transactional generation claim invalidates stale workers, including after process recovery.
    func claim(_ id: PublicationID) throws -> Publication? {
        try database.write { db in
            guard var record = try Self.record(id, in: db),
                  ![.completed, .cancelled, .capturing].contains(record.state) else { return nil }
            try db.execute(sql: "UPDATE shared_music_publication SET generation = generation + 1 WHERE id = ?", arguments: [id.uuidString])
            record = try Self.record(id, in: db)!
            record.state = .uploading
            record.error = nil
            try Self.save(record, in: db)
            return record
        }
    }
    func cancel(_ id: PublicationID) throws {
        try database.write { db in
            guard let record = try Self.record(id, in: db), record.state != .completed else { return }
            try db.execute(sql: """
                UPDATE shared_music_publication SET generation = generation + 1, state = 'cancelled',
                error = CASE WHEN error = 'finishUncertain' THEN error ELSE 'cancelled' END WHERE id = ?
                """, arguments: [id.uuidString])
        }
    }
    /// The completion owner can extend this transaction with the publication mapping.
    func complete(_ record: Publication, proof: PublicationRemoteProof, allowingCancellation: Bool = false) throws {
        try database.write { db in
            guard var current = try Self.record(record.id, in: db),
                  current.generation == record.generation ||
                    (allowingCancellation && current.state == .cancelled && current.generation == record.generation + 1),
                  current.snapshot == record.snapshot, current.destination == record.destination else {
                throw PublicationError.invalidTransition
            }
            current.state = .completed
            current.verifiedMapping = proof
            current.error = nil
            try Self.save(current, in: db)
        }
    }
    /// A typed provider rejection plus an exact absent lookup proves finish did not commit.
    func rejectFinish(_ record: Publication, error: PublicationError) throws {
        try database.write { db in
            guard var current = try Self.record(record.id, in: db),
                  current.generation == record.generation ||
                    (current.state == .cancelled && current.generation == record.generation + 1),
                  current.state != .completed, current.snapshot == record.snapshot,
                  current.destination == record.destination else { throw PublicationError.invalidTransition }
            if current.state != .cancelled { current.state = .failed }
            current.error = error
            try Self.save(current, in: db)
        }
    }
    /// Interrupted capture cannot become uploadable on restart. Originals and paired files are never removed.
    func recoverInterruptedCaptures() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE shared_music_publication SET state = 'failed', error = 'sourceChanged' WHERE state = 'capturing'")
        }
    }
}
