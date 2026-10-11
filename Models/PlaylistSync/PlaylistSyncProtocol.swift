import Foundation

/// Device-local failures deliberately carry no OAuth response or credential values.
enum PlaylistSyncError: LocalizedError {
    case invalidRevision, integrity, incomplete, conflict, staleEditor, mappingBlocked, notPaired, pairingChanged
    case transport(Int), authentication, writePermission, configuration, cancelled
    var errorDescription: String? {
        switch self {
        case .invalidRevision: return "Unsupported or invalid playlist revision."
        case .integrity: return "A revision ID has different stored contents. Sync stopped to preserve both versions."
        case .incomplete: return "Waiting for missing playlist revisions."
        case .conflict: return "This playlist has conflicting versions. Choose a version to continue."
        case .staleEditor: return "This playlist changed while the editor was open. Your draft is still here; reopen the editor to refresh."
        case .mappingBlocked: return "Some local songs could not be verified in the paired Dropbox music folder. No shortened playlist was sent."
        case .notPaired: return "Connect Dropbox and pair a music folder first."
        case .pairingChanged: return "The Dropbox account or paired music folder changed. Existing pending changes are retained."
        case .transport(let code): return "Dropbox request failed (HTTP \(code)). Retry Sync Now."
        case .authentication: return "Dropbox sign-in needs to be renewed. Pending changes are retained."
        case .writePermission: return "Enable files.content.write in the Dropbox app Permissions, then reconnect Dropbox."
        case .configuration: return "Enter a Dropbox app key and choose the matching local and Dropbox music folders."
        case .cancelled: return "Dropbox sign-in was cancelled."
        }
    }
}
struct DropboxTrackReference: Codable, Equatable, Sendable {
    var provider = "dropbox"
    var fileId: String
}
struct PlaylistRevision: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var libraryId: String
    var playlistId: String
    var revisionId: String
    var parentRevisionIds: [String]
    var deviceId: String
    var name: String
    var deleted: Bool
    var tracks: [DropboxTrackReference]
    static func uuid(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }
    static func clean(_ value: String, max: Int) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= max && !value.unicodeScalars.contains { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) }
    }
    static let nameTrimSet = CharacterSet(charactersIn: "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    func validate(library: String? = nil, playlist: String? = nil, revision: String? = nil) throws {
        guard protocolVersion == 1, [libraryId, playlistId, revisionId, deviceId].allSatisfy(Self.uuid),
              library == nil || library == libraryId, playlist == nil || playlist == playlistId,
              revision == nil || revision == revisionId, parentRevisionIds.count <= 32,
              parentRevisionIds == Array(Set(parentRevisionIds)).sorted(), parentRevisionIds.allSatisfy(Self.uuid),
              !parentRevisionIds.contains(revisionId), Self.clean(name, max: 255),
              name == name.trimmingCharacters(in: Self.nameTrimSet), tracks.count <= 10000,
              !deleted || tracks.isEmpty, Set(tracks.map(\.fileId)).count == tracks.count,
              tracks.allSatisfy({ $0.provider == "dropbox" && $0.fileId.hasPrefix("id:") && $0.fileId.count > 3 && Self.clean($0.fileId, max: 255) }) else {
            throw PlaylistSyncError.invalidRevision
        }
    }
    static func decode(_ data: Data, library: String? = nil, playlist: String? = nil, revision: String? = nil) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw PlaylistSyncError.invalidRevision }
        do {
            let result = try JSONDecoder().decode(Self.self, from: data)
            try result.validate(library: library, playlist: playlist, revision: revision)
            return result
        } catch { throw PlaylistSyncError.invalidRevision }
    }
    var path: String { ".crate-sync/v1/playlists/\(playlistId)/\(revisionId).json" }
}
struct SyncLibraryDescriptor: Codable, Equatable, Sendable {
    var protocolVersion = 1
    var libraryId: String
    var accountId: String
    var namespaceId: String
    var musicFolderId: String
    func validate() throws {
        guard protocolVersion == 1, PlaylistRevision.uuid(libraryId), PlaylistRevision.clean(accountId, max: 255), PlaylistRevision.clean(namespaceId, max: 255),
              PlaylistRevision.clean(musicFolderId, max: 255),
              (musicFolderId.hasPrefix("id:") && musicFolderId.count > 3) ||
              (musicFolderId.hasPrefix("app-folder:") && musicFolderId.count > 11 &&
               musicFolderId.dropFirst(11).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw PlaylistSyncError.invalidRevision }
    }
}
struct SyncPairing: Codable, Equatable, Sendable {
    var descriptor: SyncLibraryDescriptor
    var localRootBookmark: Data
    var localRootPath: String
    var remoteRootPath: String
}
struct RevisionGraph {
    let heads: [String]
    let incomplete: Bool
    init(revisions: [PlaylistRevision]) throws {
        var byID: [String: PlaylistRevision] = [:]
        for revision in revisions {
            if let previous = byID[revision.revisionId], previous != revision { throw PlaylistSyncError.integrity }
            byID[revision.revisionId] = revision
        }
        guard Set(revisions.map(\.libraryId)).count <= 1, Set(revisions.map(\.playlistId)).count <= 1 else {
            throw PlaylistSyncError.invalidRevision
        }
        var visited = Set<String>(), visiting = Set<String>(), absent = false
        func walk(_ id: String) throws {
            if visiting.contains(id) { throw PlaylistSyncError.invalidRevision }
            if visited.contains(id) { return }
            guard let item = byID[id] else { absent = true; return }
            visiting.insert(id)
            for parent in item.parentRevisionIds { try walk(parent) }
            visiting.remove(id)
            visited.insert(id)
        }
        for revision in revisions { try revision.validate(); try walk(revision.revisionId) }
        let parents = Set(revisions.flatMap(\.parentRevisionIds))
        heads = absent ? [] : byID.keys.filter { !parents.contains($0) }.sorted()
        incomplete = absent
    }
}
struct SyncMember: Codable, Equatable, Sendable {
    var fileId: String?
    var localTrackID: Int64?
    var localPath: String? = nil // Local-only immutable mapping evidence; never part of wire revisions.
    /// Aliases move as one ordered native-row group; unresolved slots keep relative order.
    static func projectEdit(_ members: [Self], orderedIDs: [Int64], removedIDs: Set<Int64>) -> [Self] {
        let retained = members.filter { !($0.localTrackID.map(removedIDs.contains) ?? false) }
        var groups: [Int64: [Self]] = [:]
        for member in retained { if let id = member.localTrackID { groups[id, default: []].append(member) } }
        var queue = orderedIDs.map { groups[$0] ?? [Self(fileId: nil, localTrackID: $0)] }
        let reordered = Set(orderedIDs)
        var result: [Self] = [], emitted = Set<Int64>()
        for member in retained {
            if let id = member.localTrackID, reordered.contains(id) {
                if emitted.insert(id).inserted, !queue.isEmpty { result.append(contentsOf: queue.removeFirst()) }
            } else { result.append(member) }
        }
        result.append(contentsOf: queue.flatMap { $0 })
        return result
    }
}
struct SyncIntent: Codable, Equatable, Sendable {
    var generation: Int64
    var name: String
    var deleted: Bool
    var members: [SyncMember]
    var parents: [String]
}
struct PlaylistEditorSnapshot: Equatable, Sendable {
    var name: String
    var trackIDs: [Int64]
    var generation: Int64
}
enum PlaylistSyncMutation {
    case metadata, append, remove(Set<Int64>), order, replace(Set<Int64>), delete
}
