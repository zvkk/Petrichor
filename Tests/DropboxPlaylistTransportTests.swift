import AuthenticationServices
import Foundation
import GRDB
import XCTest
@testable import Petrichor

private final class DropboxFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let (status, data) = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class DropboxPlaylistTransportTests: XCTestCase {
    override func tearDown() { DropboxFixtureProtocol.handler = nil }
    private func client() -> DropboxPlaylistTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DropboxFixtureProtocol.self]
        return DropboxPlaylistTransport(accessToken: "fixture-access", namespace: "fixture-namespace", session: URLSession(configuration: configuration))
    }
    func testExplicitAppFolderRootOmitsNamespaceOnlyAfterSpecificRejection() async throws {
        var requests: [URLRequest] = []
        DropboxFixtureProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 {
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Dropbox-API-Path-Root"))
                XCTAssertTrue(request.url!.path.hasSuffix("/list_folder"))
                return (400, Data("Error: path root is not supported for sandbox app".utf8))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Dropbox-API-Path-Root"))
            if request.url!.path.hasSuffix("/upload") {
                let arg = try XCTUnwrap(request.value(forHTTPHeaderField: "Dropbox-API-Arg"))
                let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: Any])
                XCTAssertEqual(args["path"] as? String, "/.crate-sync/v1/library.json")
                XCTAssertFalse(arg.contains("app-folder:"))
            }
            return (200, Data("{\"entries\":[],\"cursor\":\"fixture\",\"has_more\":false}".utf8))
        }
        let transport = client()
        let folder = try await transport.musicFolder("/", appKey: "fixtureKey123")
        XCTAssertEqual(folder.id, "app-folder:fixtureKey123")
        XCTAssertEqual(folder.path_display, "")
        let path = transport.musicPath(try XCTUnwrap(folder.id), ".crate-sync/v1/library.json")
        XCTAssertEqual(path, "/.crate-sync/v1/library.json")
        try await transport.immutableUpload(path, body: Data("{}".utf8))
        XCTAssertEqual(requests.count, 3)
    }
    func testAppFolderRootDoesNotFallbackForOtherFailuresOrFullDropbox() async throws {
        for status in [200, 400, 401, 403, 409] {
            var count = 0
            DropboxFixtureProtocol.handler = { _ in count += 1; return (status, Data("unrelated response".utf8)) }
            do { _ = try await client().musicFolder("/", appKey: "fixtureKey123"); XCTFail("Must reject \(status)") }
            catch { }
            XCTAssertEqual(count, 1)
        }
        var count = 0
        DropboxFixtureProtocol.handler = { _ in count += 1; return (200, Data()) }
        do { _ = try await client().musicFolder("app-folder:otherKey", appKey: "fixtureKey123"); XCTFail("Must reject a changed app key") }
        catch PlaylistSyncError.pairingChanged { }
        XCTAssertEqual(count, 0)
    }
    func testCreateConflictVerifiesExactBytesWithPinnedRootAndNoAutorename() async throws {
        let body = Data("immutable revision".utf8)
        var requests: [URLRequest] = []
        DropboxFixtureProtocol.handler = { request in
            requests.append(request)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Dropbox-API-Path-Root"))
            if request.url!.path.hasSuffix("/upload") {
                let args = try XCTUnwrap(request.value(forHTTPHeaderField: "Dropbox-API-Arg"))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any])
                XCTAssertEqual(object["autorename"] as? Bool, false)
                XCTAssertEqual(object["strict_conflict"] as? Bool, true)
                return (409, Data("{\"error_summary\":\"path/conflict/file\"}".utf8))
            }
            if request.url!.path.hasSuffix("/get_metadata") {
                return (200, Data("{\".tag\":\"file\",\"id\":\"id:revision\",\"size\":18}".utf8))
            }
            return (200, body)
        }
        try await client().immutableUpload("id:music/.crate-sync/v1/revision.json", body: body)
        XCTAssertEqual(requests.count, 3)
    }
    func testCreateConflictDifferentBodyIsHardIntegrityFailure() async throws {
        DropboxFixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("/upload") { return (409, Data("{\"error_summary\":\"path/conflict/file\"}".utf8)) }
            if request.url!.path.hasSuffix("/get_metadata") { return (200, Data("{\".tag\":\"file\",\"size\":5}".utf8)) }
            return (200, Data("other".utf8))
        }
        do { try await client().immutableUpload("id:music/revision.json", body: Data("first".utf8)); XCTFail("Expected integrity failure") }
        catch PlaylistSyncError.integrity { }
    }
    func testCursorResetAndAuthFailureNeverTryAnotherRoot() async throws {
        var count = 0
        DropboxFixtureProtocol.handler = { _ in count += 1; return (409, Data("{\"error_summary\":\"reset\"}".utf8)) }
        do { _ = try await client().list("id:music/.crate-sync/v1", cursor: "old"); XCTFail("Expected cursor reset") }
        catch DropboxRequestError.cursorReset { }
        XCTAssertEqual(count, 1)
        DropboxFixtureProtocol.handler = { _ in count += 1; return (401, Data()) }
        do { _ = try await client().metadata("id:music"); XCTFail("Expected authentication error") }
        catch PlaylistSyncError.authentication { }
        XCTAssertEqual(count, 2)
    }
    func testDropboxContentHashUsesChunkHashDigests() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        XCTAssertEqual(try DropboxPlaylistTransport.contentHash(file), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try DropboxPlaylistTransport.contentHash(file), "4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358")
    }
    @MainActor
    func testCancelledAuthenticationCanRetryAndFalseStartCompletesOnce() async throws {
        final class CancelledSession: DropboxWebAuthenticationSession {
            var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
            var prefersEphemeralWebBrowserSession = false
            let completion: (URL?, Error?) -> Void
            init(_ completion: @escaping (URL?, Error?) -> Void) { self.completion = completion }
            func start() -> Bool { completion(nil, PlaylistSyncError.cancelled); return false }
        }
        let prior = UserDefaults.standard.object(forKey: "dropboxPlaylistAppKey")
        defer { if let prior { UserDefaults.standard.set(prior, forKey: "dropboxPlaylistAppKey") } else { UserDefaults.standard.removeObject(forKey: "dropboxPlaylistAppKey") } }
        UserDefaults.standard.set("fixture-public-key", forKey: "dropboxPlaylistAppKey")
        var starts = 0
        let auth = DropboxPlaylistAuthentication { _, _, completion in starts += 1; return CancelledSession(completion) }
        for _ in 0..<2 {
            do { try await auth.connect(); XCTFail("Expected cancellation") }
            catch PlaylistSyncError.cancelled { }
        }
        XCTAssertEqual(starts, 2)
    }
}

extension DropboxPlaylistTransportTests {
    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            if count < 0 { throw stream.streamError ?? PlaylistSyncError.transport(0) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    func testFolderCreationRequiresWritePathAndDoesNotUseIDPath() async throws {
        var count = 0
        DropboxFixtureProtocol.handler = { request in
            count += 1
            let body = try Self.requestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["path"] as? String, "/Music/.crate-sync/v1")
            return (200, Data("{}".utf8))
        }
        do { try await client().ensureFolder("id:music/.crate-sync/v1"); XCTFail("WritePath forbids folder IDs") }
        catch PlaylistSyncError.configuration { }
        XCTAssertEqual(count, 0)
        try await client().ensureFolder(DropboxPlaylistTransport.childPath("/Music", ".crate-sync/v1"))
        XCTAssertEqual(count, 1)
    }
    @MainActor
    func testMissingDescriptorRecreationUsesExistingLibraryIdentity() throws {
        let descriptor = SyncLibraryDescriptor(libraryId: UUID().uuidString.lowercased(), accountId: "dbid:paired", namespaceId: "paired", musicFolderId: "id:music")
        let pairing = SyncPairing(descriptor: descriptor, localRootBookmark: Data(), localRootPath: "/Local", remoteRootPath: "/Music")
        XCTAssertEqual(try DropboxPlaylistSyncCoordinator.pairingDescriptor(existing: pairing, accountID: "dbid:paired", namespace: "paired", folderID: "id:music", localRoot: "/Local"), descriptor)
        XCTAssertThrowsError(try DropboxPlaylistSyncCoordinator.pairingDescriptor(existing: pairing, accountID: "dbid:other", namespace: "paired", folderID: "id:music", localRoot: "/Local"))
    }
    func testPreviouslyMappedChangedContentsAndMovedRemoteBecomeUnresolvedWithoutDroppingRefs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try DatabaseManager(databaseURL: root.appendingPathComponent("test.db"))
        let song = root.appendingPathComponent("song.wav")
        try Data("original".utf8).write(to: song)
        let originalHash = try DropboxPlaylistTransport.contentHash(song)
        let trackID = try await db.dbQueue.write { database in
            var folder = Folder(url: root)
            try folder.insert(database)
            folder.id = database.lastInsertedRowID
            try database.execute(sql: "INSERT INTO tracks (folder_id, path, filename, title, artist, album, composer, genre, year, duration, format, date_added, is_duplicate) VALUES (?, ?, 'song.wav', 'Song', 'Artist', 'Album', 'Composer', 'Genre', '2026', 0.1, 'wav', ?, 0)", arguments: [folder.id, song.path, Date()])
            return database.lastInsertedRowID
        }
        let revision = PlaylistRevision(protocolVersion: 1, libraryId: UUID().uuidString.lowercased(), playlistId: UUID().uuidString.lowercased(),
            revisionId: UUID().uuidString.lowercased(), parentRevisionIds: [], deviceId: UUID().uuidString.lowercased(), name: "Verified", deleted: false,
            tracks: [DropboxTrackReference(fileId: "id:song")])
        try db.saveSyncMapping(fileID: "id:song", trackID: trackID, hash: originalHash)
        try db.receiveSyncRevision(JSONEncoder().encode(revision), path: revision.path, library: revision.libraryId)
        try db.projectSyncRevisions()
        let state = try XCTUnwrap(db.syncStates().first)
        XCTAssertEqual(db.loadTracksForPlaylist(state.localID).count, 1)
        try Data("changed".utf8).write(to: song)
        DropboxFixtureProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: [".tag": "file", "id": "id:song", "path_display": "/Music/song.wav", "content_hash": originalHash])) }
        do { try await DropboxPlaylistMapping.refreshRemote("id:song", root: root, remoteRootPath: "/Music", client: client(), db: db); XCTFail("Changed content must invalidate") }
        catch PlaylistSyncError.mappingBlocked { }
        try db.projectSyncRevisions()
        XCTAssertTrue(db.loadTracksForPlaylist(state.localID).isEmpty)
        XCTAssertEqual(try db.syncStates().first?.members.map(\.fileId), ["id:song"])
        XCTAssertTrue(try db.syncOutbox().isEmpty)
        try db.saveSyncMapping(fileID: "id:song", trackID: trackID, hash: originalHash)
        DropboxFixtureProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: [".tag": "file", "id": "id:song", "path_display": "/Outside/song.wav", "content_hash": originalHash])) }
        do { try await DropboxPlaylistMapping.refreshRemote("id:song", root: root, remoteRootPath: "/Music", client: client(), db: db); XCTFail("Moved file outside pinned root must invalidate") }
        catch PlaylistSyncError.mappingBlocked { }
        XCTAssertNil(try db.syncMapping(fileID: "id:song"))
        XCTAssertEqual(try db.syncStates().first?.members.map(\.fileId), ["id:song"])
    }
}
