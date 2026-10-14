import Foundation

/// Shared persisted preview preferences; playback keeps invalid values safe at zero.
struct PreviewSettings: Equatable {
    enum Keys {
        static let fraction = "previewFraction"
        static let minSeconds = "previewMinSeconds"
        static let maxSeconds = "previewMaxSeconds"
    }

    static let defaults = PreviewSettings(fraction: 0.2, minSeconds: 20, maxSeconds: 75)

    var fraction: Double
    var minSeconds: Double
    var maxSeconds: Double

    static func load(from defaults: UserDefaults = .standard) -> PreviewSettings {
        func value(_ key: String, fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        return PreviewSettings(
            fraction: value(Keys.fraction, fallback: Self.defaults.fraction),
            minSeconds: value(Keys.minSeconds, fallback: Self.defaults.minSeconds),
            maxSeconds: value(Keys.maxSeconds, fallback: Self.defaults.maxSeconds)
        )
    }

    var isValid: Bool {
        (try? PreviewPolicy.startSeconds(
            duration: 0,
            fraction: fraction,
            minSeconds: minSeconds,
            maxSeconds: maxSeconds
        )) != nil
    }

    /// Controls display valid defaults without weakening playback's invalid-value fallback.
    var validOrDefault: PreviewSettings { isValid ? self : Self.defaults }

    func startSeconds(duration: Double) -> Double {
        (try? PreviewPolicy.startSeconds(
            duration: duration,
            fraction: fraction,
            minSeconds: minSeconds,
            maxSeconds: maxSeconds
        )) ?? 0
    }
}
