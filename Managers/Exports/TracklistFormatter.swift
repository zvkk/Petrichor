import Foundation

enum TracklistFormatter {
    static func render(_ tracks: [ExportTrack], numbered: Bool = true, includeLabel: Bool = false) -> String {
        let width = max(2, String(tracks.count).count)
        return tracks.enumerated().map { index, track in
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = track.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prefix = numbered ? String(format: "%0*d. ", width, index + 1) : ""
            return prefix + (artist.isEmpty ? String(localized: "Unknown Artist") : artist) + " — " + (title.isEmpty ? String(localized: "Untitled") : title)
                + (includeLabel && !label.isEmpty ? " [\(label)]" : "")
        }.joined(separator: "\n")
    }
}
