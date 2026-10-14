import Foundation

enum PreviewPolicy {
    enum InvalidSettings: Error { case invalidRange }

    static func startSeconds(duration: Double, fraction: Double = 0.2,
                             minSeconds: Double = 20, maxSeconds: Double = 75) throws -> Double {
        guard fraction.isFinite, (0...1).contains(fraction), minSeconds.isFinite,
              maxSeconds.isFinite, minSeconds >= 0, minSeconds <= maxSeconds else {
            throw InvalidSettings.invalidRange
        }
        guard duration.isFinite, duration > 0 else { return 0 }
        let start = min(max(duration * fraction, minSeconds), maxSeconds).rounded()
        return duration - start >= 5 ? start : 0
    }
}
