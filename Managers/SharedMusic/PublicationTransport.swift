import Foundation

protocol PublicationTransport {
    func checkValidity() throws
    func metadataAtDestination() async throws -> PublicationRemoteProof?
    func start() async throws -> String
    /// Returns confirmed end offset; a lost append response may be reconciled by correct_offset.
    func append(session: String, offset: UInt64, bytes: Data) async throws -> UInt64
    func finish(session: String, offset: UInt64) async throws
}

extension PublicationTransport {
    func checkValidity() throws {}
}

/// Changes whenever the credential owner replaces or removes the connection. Tokens never enter rows.
final class PublicationConnectionEpoch: @unchecked Sendable {
    static let shared = PublicationConnectionEpoch()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    func current() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func invalidate() { lock.lock(); defer { lock.unlock() }; generation &+= 1 }
}

final class DropboxPublicationTransport: PublicationTransport {
    private let client: DropboxPlaylistTransport
    private let destination: String
    private let expectedPath: String
    private let validate: () throws -> Void
    init(client: DropboxPlaylistTransport, destination: String, expectedPath: String, validate: @escaping () throws -> Void) {
        self.client = client
        self.destination = destination
        self.expectedPath = expectedPath
        self.validate = validate
        client.publicationValidity = validate
    }
    /// Reuses the native credential owner and the exact pairing verification used by playlist sync.
    @MainActor
    static func verified(record: Publication, manager: DatabaseManager,
                         authentication: DropboxPlaylistAuthentication,
                         credentialProvider: (() async throws -> DropboxSyncCredentials)? = nil) async throws -> DropboxPublicationTransport {
        let pairing = record.snapshot.pairing
        guard try manager.syncPairing() == pairing else { throw PublicationError.root }
        let epoch = PublicationConnectionEpoch.shared.current()
        let credentials: DropboxSyncCredentials
        if let credentialProvider { credentials = try await credentialProvider() }
        else { credentials = try await authentication.credentials(forceRefresh: pairing.descriptor.musicFolderId.hasPrefix("app-folder:")) }
        let validate = {
            guard PublicationConnectionEpoch.shared.current() == epoch else { throw PublicationError.auth }
            guard try manager.syncPairing() == pairing else { throw PublicationError.root }
        }
        try validate()
        let accountClient = DropboxPlaylistTransport(accessToken: credentials.accessToken)
        accountClient.publicationValidity = validate
        let account = try await accountClient.account()
        guard account.account_id == pairing.descriptor.accountId,
              account.root_info.root_namespace_id == pairing.descriptor.namespaceId else { throw PublicationError.root }
        try validate()
        let client = DropboxPlaylistTransport(accessToken: credentials.accessToken, namespace: pairing.descriptor.namespaceId)
        client.publicationValidity = validate
        let folder = try await client.musicFolder(pairing.descriptor.musicFolderId, appKey: authentication.appKey)
        guard folder.tag == "folder", folder.id == pairing.descriptor.musicFolderId,
              let rootPath = folder.path_display else { throw PublicationError.root }
        try validate()
        let descriptor = try JSONDecoder().decode(SyncLibraryDescriptor.self, from: await client.download(
            client.musicPath(pairing.descriptor.musicFolderId, ".crate-sync/v1/library.json")))
        try descriptor.validate()
        guard descriptor == pairing.descriptor else { throw PublicationError.root }
        _ = try PublicationSource.components(record.destination)
        return DropboxPublicationTransport(client: client,
            destination: client.musicPath(pairing.descriptor.musicFolderId, record.destination),
            expectedPath: DropboxPlaylistTransport.childPath(rootPath, record.destination), validate: validate)
    }
    func checkValidity() throws { try validate() }
    func metadataAtDestination() async throws -> PublicationRemoteProof? {
        try validate()
        do {
            let info = try await client.metadata(destination)
            guard info.tag == "file", let id = info.id, id.hasPrefix("id:"), id.count > 3,
                  let hash = info.content_hash, hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  let size = info.size, size >= 0,
                  info.path_lower == expectedPath.lowercased() else { throw PublicationError.contentMismatch }
            return PublicationRemoteProof(fileID: id, contentHash: hash, size: UInt64(size))
        } catch DropboxRequestError.notFound { return nil }
        catch { throw Self.classify(error) }
    }
    func start() async throws -> String {
        try validate()
        let data = try await client.publicationRequest("start", arguments: ["close": false], bytes: Data())
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["session_id"] as? String, !id.isEmpty, id.count <= 1024 else { throw PublicationError.retryable }
        return id
    }
    func append(session: String, offset: UInt64, bytes: Data) async throws -> UInt64 {
        try validate()
        guard !bytes.isEmpty, bytes.count <= PublicationService.chunkSize else { throw PublicationError.integrity }
        let end = offset + UInt64(bytes.count)
        do {
            _ = try await client.publicationRequest("append_v2", arguments: ["cursor": ["session_id": session, "offset": offset], "close": false], bytes: bytes)
        } catch PublicationOffsetError.correct(let confirmed) {
            guard confirmed == end else { throw PublicationError.retryable }
        }
        return end
    }
    func finish(session: String, offset: UInt64) async throws {
        try validate()
        _ = try await client.publicationRequest("finish", arguments: ["cursor": ["session_id": session, "offset": offset],
            "commit": ["path": destination, "mode": [".tag": "add"], "autorename": false, "strict_conflict": true, "mute": true]], bytes: Data())
    }
    static func classify(_ error: Error) -> PublicationError {
        if let domain = error as? PublicationError { return domain }
        if error is DecodingError { return .root }
        if let domain = error as? PlaylistSyncError {
            switch domain {
            case .authentication, .writePermission: return .auth
            case .pairingChanged, .notPaired, .configuration: return .root
            default: return .retryable
            }
        }
        return .retryable
    }
}

enum PublicationOffsetError: Error { case correct(UInt64) }
