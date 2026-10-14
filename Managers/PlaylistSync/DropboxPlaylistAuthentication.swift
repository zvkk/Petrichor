import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct DropboxSyncCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}
/// Separate native keychain item; no logging of authorization URLs, codes or tokens.
enum DropboxSyncVault {
    static var key: String { "\(Bundle.main.bundleIdentifier ?? "org.Petrichor").dropbox.playlist-sync" }
    /// Presentation must never retrieve secrets or display a Keychain permission prompt.
    /// An interaction-required result still means a saved connection may exist; explicit
    /// Connect/Sync owns reauthorization rather than showing a false disconnected state.
    static func hasSavedCredentials(check: (CFDictionary) -> OSStatus = { SecItemCopyMatching($0, nil) }) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecMatchLimit as String: kSecMatchLimitOne]
        return check(query as CFDictionary) != errSecItemNotFound
    }
    static func load() throws -> DropboxSyncCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PlaylistSyncError.authentication }
        return try JSONDecoder().decode(DropboxSyncCredentials.self, from: data)
    }
    static func save(_ credentials: DropboxSyncCredentials) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PlaylistSyncError.authentication }
        } else if status != errSecSuccess { throw PlaylistSyncError.authentication }
    }
    static func disconnect() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PlaylistSyncError.authentication }
    }
}
protocol DropboxWebAuthenticationSession: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
}
extension ASWebAuthenticationSession: DropboxWebAuthenticationSession {}
private final class DropboxAuthCompletion: @unchecked Sendable {
    let continuation: CheckedContinuation<URL, Error>
    let lock = NSLock()
    var finished = false
    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    func resume(url: URL?, error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        if error != nil || url == nil { continuation.resume(throwing: PlaylistSyncError.cancelled) }
        else { continuation.resume(returning: url!) }
    }
}
@MainActor
final class DropboxPlaylistAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias SessionFactory = (URL, String, @escaping (URL?, Error?) -> Void) -> any DropboxWebAuthenticationSession
    private let sessionFactory: SessionFactory
    private var webSession: (any DropboxWebAuthenticationSession)?
    init(sessionFactory: @escaping SessionFactory = { ASWebAuthenticationSession(url: $0, callbackURLScheme: $1, completionHandler: $2) }) {
        self.sessionFactory = sessionFactory
        super.init()
    }
    var redirectURI: String { "\(AppInfo.urlScheme)://dropbox-callback" }
    var appKey: String {
        let configured = UserDefaults.standard.string(forKey: "dropboxPlaylistAppKey") ?? ""
        let bundled = Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String ?? ""
        let result = configured.isEmpty ? bundled : configured
        return result.contains("$(") ? "" : result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PlaylistSyncError.authentication }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func connect() async throws {
        guard !appKey.isEmpty, webSession == nil else { throw PlaylistSyncError.configuration }
        let verifier = try Self.random(), state = try Self.random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        url.queryItems = [URLQueryItem(name: "client_id", value: appKey), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "scope", value: "account_info.read files.metadata.read files.content.read files.content.write")]
        defer { webSession = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let completion = DropboxAuthCompletion(continuation)
            webSession = sessionFactory(url.url!, AppInfo.urlScheme) { callback, error in completion.resume(url: callback, error: error) }
            webSession?.presentationContextProvider = self
            webSession?.prefersEphemeralWebBrowserSession = true
            if webSession?.start() != true { completion.resume(url: nil, error: PlaylistSyncError.authentication) }
        }
        webSession = nil
        guard callback.scheme == AppInfo.urlScheme, callback.host == "dropbox-callback",
              let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name == "state" }).count == 1, query.first(where: { $0.name == "state" })?.value == state,
              query.filter({ $0.name == "code" }).count == 1, let code = query.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { throw PlaylistSyncError.authentication }
        let credentials = try await token(["grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "client_id": appKey, "redirect_uri": redirectURI], previousRefresh: nil)
        try DropboxSyncVault.save(credentials)
    }
    private func token(_ values: [String: String], previousRefresh: String?) async throws -> DropboxSyncCredentials {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(values.sorted(by: { $0.key < $1.key }).map { "\($0.key.addingPercentEncoding(withAllowedCharacters: safe)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: safe)!)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = object["refresh_token"] as? String ?? previousRefresh, !refresh.isEmpty,
              let expires = object["expires_in"] as? Double else { throw PlaylistSyncError.authentication }
        return DropboxSyncCredentials(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires))
    }
    func credentials(forceRefresh: Bool = false) async throws -> DropboxSyncCredentials {
        guard var credentials = try DropboxSyncVault.load() else { throw PlaylistSyncError.authentication }
        if forceRefresh || credentials.expiresAt.timeIntervalSinceNow < 120 {
            guard !appKey.isEmpty else { throw PlaylistSyncError.configuration }
            credentials = try await token(["grant_type": "refresh_token", "refresh_token": credentials.refreshToken, "client_id": appKey], previousRefresh: credentials.refreshToken)
            try DropboxSyncVault.save(credentials)
        }
        return credentials
    }
}
