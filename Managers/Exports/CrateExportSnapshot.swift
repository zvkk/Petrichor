import Foundation
import GRDB

/// Value copies only: neither table sort nor subsequent library edits can change an export.
struct ExportTrack: Sendable {
    var sharedID: String? = nil
    var nativeID: Int64? = nil
    var localURL: URL? = nil
    var title: String = ""
    var artist: String = ""
    var album: String? = nil
    var genre: String? = nil
    var label: String? = nil
    var key: String? = nil
    var bpm: Double? = nil
    var duration: Double? = nil
    var year: Int? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var sampleRate: Int? = nil
    var fileSize: Int64? = nil
    var bitrate: Int? = nil
    var hasDisplayMetadata: Bool = true
}

struct CrateExportSnapshot: Sendable {
    let name: String
    let tracks: [ExportTrack]
}

enum CrateExportError: LocalizedError {
    case unavailableCrate, empty, unavailableMedia
    var errorDescription: String? {
        switch self {
        case .unavailableCrate: "This crate is no longer available."
        case .empty: "This crate has no tracks to export."
        case .unavailableMedia: "Some tracks have no available local audio."
        }
    }
}

extension PlaylistManager {
    @MainActor
    func captureExportSnapshot(playlistID: UUID) async throws -> CrateExportSnapshot {
        guard let playlist = playlists.first(where: { $0.id == playlistID }), playlist.type != .stations,
              let database = libraryManager?.databaseManager else { throw CrateExportError.unavailableCrate }
        // Read membership, metadata and shared unresolved slots in the same database snapshot.
        let rows: [(FullTrack?, String?)]
        if playlist.type == .smart && (playlist.smartCriteria?.autoUpdate ?? true) {
            let evaluated = try await database.getTracksForSmartPlaylist(playlist)
            rows = try await database.dbQueue.read { db in
                try evaluated.map { track in
                    (try track.trackId.flatMap { try FullTrack.fetchOne(db, key: $0) }, nil)
                }
            }
        } else {
            rows = try await database.dbQueue.read { db in
                if let state = try database.syncState(db, localID: playlistID) {
                    return try (state.intent?.members ?? state.members).map { member in
                        let track = try member.localTrackID.flatMap { try FullTrack.fetchOne(db, key: $0) }
                        return (track, member.fileId)
                    }
                }
                return try PlaylistTrack.filter(PlaylistTrack.Columns.playlistId == playlistID.uuidString)
                    .order(PlaylistTrack.Columns.position).fetchAll(db).map { member in
                        (try FullTrack.fetchOne(db, key: member.trackId), nil)
                    }
            }
        }
        var frozen: [ExportTrack] = []
        for (track, sharedID) in rows {
            guard let track else {
                frozen.append(ExportTrack(sharedID: sharedID, title: "Unavailable shared track (item \(frozen.count + 1))", hasDisplayMetadata: false))
                continue
            }
            var value = ExportTrack(sharedID: sharedID, nativeID: track.trackId, title: track.title, artist: track.artist,
                album: track.album, genre: track.genre, label: track.extendedMetadata?.label, key: track.extendedMetadata?.key, bpm: track.bpm.map(Double.init), duration: track.duration, year: Int(track.year),
                trackNumber: track.trackNumber, discNumber: track.discNumber)
            if track.url.isFileURL, FileManager.default.isReadableFile(atPath: track.url.path),
               let info = try? track.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true {
                value.localURL = track.url
                value.fileSize = info.fileSize.map(Int64.init)
                let metadata = await MetadataEngine.extractMetadata(from: track.url)
                value.label = metadata.extended.label ?? value.label
                value.key = metadata.extended.key ?? value.key
                value.bpm = metadata.bpm.map(Double.init) ?? value.bpm
                value.sampleRate = metadata.sampleRate
                value.bitrate = metadata.bitrate
                if metadata.duration.isFinite, metadata.duration > 0 { value.duration = metadata.duration }
            }
            frozen.append(value)
        }
        return CrateExportSnapshot(name: playlist.name, tracks: frozen)
    }
}
