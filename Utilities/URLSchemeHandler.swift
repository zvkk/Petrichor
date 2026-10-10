import Foundation

enum URLSchemeHandler {
    static func handle(_ url: URL) {
        guard url.scheme == AppInfo.urlScheme else { return }

        Logger.info("URLSchemeHandler: Received callback - \(url.scheme ?? "nil")://\(url.host ?? "nil")")
        
        switch url.host {
        case "dropbox-callback":
            break // ASWebAuthenticationSession owns its state-checked native callback.
        case "lastfm-callback":
            AppCoordinator.shared?.scrobbleManager.handleAuthCallback(url)
        default:
            Logger.warning("URLSchemeHandler: Unknown callback - \(url.host ?? "nil")")
        }
    }
}
