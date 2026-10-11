import Foundation
import CryptoKit

struct DropboxSyncAccount: Decodable {
    var account_id: String
    struct Root: Decodable { var root_namespace_id: String }
    var root_info: Root
}
struct DropboxSyncMetadata: Decodable {
    var id: String?
    var path_display: String?
    var path_lower: String?
    var content_hash: String?
    var size: Int64?
    var tag: String
    enum CodingKeys: String, CodingKey { case id, path_display, path_lower, content_hash, size; case tag = ".tag" }
}
struct DropboxSyncPage: Decodable {
    var entries: [DropboxSyncMetadata]
    var cursor: String
    var has_more: Bool
}
enum DropboxRequestError: Error { case notFound, conflict, cursorReset, appFolderOnly }

/// Native metadata transport. Audio bytes are only read locally to verify Dropbox's hash.
final class DropboxPlaylistTransport {
    let accessToken: String
    let namespace: String?
    private var appFolderRoot = false
    let session: URLSession
    init(accessToken: String, namespace: String? = nil, session: URLSession = .shared) {
        self.accessToken = accessToken; self.namespace = namespace; self.session = session
    }
    private func request(_ endpoint: String, arguments: [String: Any]?, content: Data? = nil, download: Bool = false) async throws -> Data {
        let host = (content != nil || download) ? "content.dropboxapi.com" : "api.dropboxapi.com"
        let url = URL(string: "https://\(host)/2/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let namespace, !appFolderRoot {
            let root = try JSONSerialization.data(withJSONObject: [".tag": "namespace_id", "namespace_id": namespace])
            request.setValue(String(data: root, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Path-Root")
        }
        let json = try JSONSerialization.data(withJSONObject: arguments as Any? ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
        if content != nil || download {
            // Header JSON must be ASCII; Foundation escapes non-ASCII scalars below.
            let raw = String(data: json, encoding: .utf8)!
            let escaped = raw.unicodeScalars.map { scalar in scalar.value < 128 ? String(scalar) : scalar.value <= 0xffff ? String(format: "\\u%04x", scalar.value) : {
                let value = scalar.value - 0x10000
                return String(format: "\\u%04x\\u%04x", 0xd800 + (value >> 10), 0xdc00 + (value & 0x3ff))
            }() }.joined()
            request.setValue(escaped, forHTTPHeaderField: "Dropbox-API-Arg")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = content
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        }
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PlaylistSyncError.transport(0) }
            if (200..<300).contains(http.statusCode) { return data }
            if http.statusCode == 401 { throw PlaylistSyncError.authentication }
            if http.statusCode == 400,
               String(data: data, encoding: .utf8)?.contains("does not have the required scope 'files.content.write'") == true {
                throw PlaylistSyncError.writePermission
            }
            if http.statusCode == 400, endpoint == "files/list_folder", arguments?["path"] as? String == "",
               arguments?["limit"] as? Int == 1, !appFolderRoot,
               String(data: data, encoding: .utf8)?.contains("path root is not supported for sandbox app") == true {
                throw DropboxRequestError.appFolderOnly
            }
            if http.statusCode == 409 {
                // Never expose the response; only classify known transport tags.
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let summary = object?["error_summary"] as? String ?? ""
                if summary.contains("not_found") { throw DropboxRequestError.notFound }
                if summary.contains("conflict") { throw DropboxRequestError.conflict }
                if summary.contains("reset") { throw DropboxRequestError.cursorReset }
            }
            if (http.statusCode == 429 || http.statusCode >= 500), attempt < 2 {
                let retry = min(8, max(1, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? (1 << attempt)))
                try await Task.sleep(nanoseconds: UInt64(retry) * 1_000_000_000)
                continue
            }
            throw PlaylistSyncError.transport(http.statusCode)
        }
        throw PlaylistSyncError.transport(0)
    }
    func account() async throws -> DropboxSyncAccount {
        try JSONDecoder().decode(DropboxSyncAccount.self, from: await request("users/get_current_account", arguments: nil))
    }
    func metadata(_ path: String) async throws -> DropboxSyncMetadata {
        try JSONDecoder().decode(DropboxSyncMetadata.self, from: await request("files/get_metadata", arguments: ["path": path, "include_deleted": false]))
    }
    /// `/` explicitly selects this application's folder, never a full Dropbox account root.
    /// Dropbox has no ordinary folder metadata/ID for an app root, so bind it to the app key.
    func musicFolder(_ selection: String, appKey: String) async throws -> DropboxSyncMetadata {
        appFolderRoot = false
        guard selection == "/" || selection.hasPrefix("app-folder:") else { return try await metadata(selection) }
        guard !appKey.isEmpty, appKey.count <= 244, appKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              selection == "/" || selection == "app-folder:" + appKey,
              namespace != nil else { throw PlaylistSyncError.pairingChanged }
        // Only the specific app-folder rejection authorizes headerless app-root access.
        do {
            _ = try await request("files/list_folder", arguments: ["path": "", "limit": 1])
            throw PlaylistSyncError.configuration
        } catch DropboxRequestError.appFolderOnly { }
        appFolderRoot = true
        do { _ = try await request("files/list_folder", arguments: ["path": "", "limit": 1]) }
        catch { appFolderRoot = false; throw error }
        return DropboxSyncMetadata(id: "app-folder:" + appKey, path_display: "", path_lower: "", tag: "folder")
    }
    func musicPath(_ folderID: String, _ relative: String) -> String {
        Self.childPath(appFolderRoot ? "" : folderID, relative)
    }
    func download(_ path: String) async throws -> Data {
        let info = try await metadata(path)
        guard info.tag == "file", let size = info.size, size <= 2 * 1024 * 1024 else { throw PlaylistSyncError.invalidRevision }
        let body = try await request("files/download", arguments: ["path": path], download: true)
        guard body.count <= 2 * 1024 * 1024 else { throw PlaylistSyncError.invalidRevision }
        return body
    }
    func immutableUpload(_ path: String, body: Data) async throws {
        do {
            _ = try await request("files/upload", arguments: ["path": path, "mode": [".tag": "add"], "autorename": false,
                "strict_conflict": true, "mute": true], content: body)
        } catch DropboxRequestError.conflict {
            guard try await download(path) == body else { throw PlaylistSyncError.integrity }
        }
        // Other ambiguous failures preserve the exact outbox body for the next retry.
    }
    static func childPath(_ parent: String, _ relative: String) -> String {
        (parent.hasSuffix("/") ? String(parent.dropLast()) : parent) + "/" + relative
    }
    func ensureFolder(_ path: String) async throws {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { throw PlaylistSyncError.configuration }
        do { _ = try await request("files/create_folder_v2", arguments: ["path": path, "autorename": false]) }
        catch DropboxRequestError.conflict {
            guard try await metadata(path).tag == "folder" else { throw PlaylistSyncError.pairingChanged }
        }
    }
    func list(_ path: String, cursor: String?) async throws -> DropboxSyncPage {
        if let cursor {
            return try JSONDecoder().decode(DropboxSyncPage.self, from: await request("files/list_folder/continue", arguments: ["cursor": cursor]))
        }
        return try JSONDecoder().decode(DropboxSyncPage.self, from: await request("files/list_folder", arguments: ["path": path,
            "recursive": true, "include_deleted": false, "include_mounted_folders": false]))
    }
    static func contentHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var combined = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            combined.update(data: Data(SHA256.hash(data: chunk)))
        }
        return combined.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
