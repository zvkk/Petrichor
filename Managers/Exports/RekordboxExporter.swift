import Foundation

enum RekordboxExporter {
    static func render(_ snapshot: CrateExportSnapshot) throws -> Data {
        guard !snapshot.tracks.isEmpty else { throw CrateExportError.empty }
        guard snapshot.tracks.allSatisfy({ track in
            guard let url = track.localURL, url.isFileURL else { return false }
            return FileManager.default.isReadableFile(atPath: url.path)
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }) else { throw CrateExportError.unavailableMedia }
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<DJ_PLAYLISTS Version=\"1.0.0\">",
            "<PRODUCT Name=\"Crate Mac\" Version=\"1\" Company=\"Crate\"/>",
            "<COLLECTION Entries=\"\(snapshot.tracks.count)\">"
        ]
        for (index, track) in snapshot.tracks.enumerated() {
            var attributes: [(String, String)] = [("TrackID", String(index + 1)), ("Name", track.title), ("Artist", track.artist), ("Location", location(track.localURL!))]
            func add<T>(_ name: String, _ value: T?) { if let value { attributes.append((name, String(describing: value))) } }
            add("Album", track.album); add("Genre", track.genre); add("Label", track.label); add("Tonality", track.key)
            if let bpm = track.bpm, bpm.isFinite, bpm > 0 { add("AverageBpm", bpm) }
            if let duration = track.duration, duration.isFinite, duration >= 0 { add("TotalTime", Int(exactly: duration.rounded(.down))) }
            add("Year", track.year); add("TrackNumber", track.trackNumber); add("DiscNumber", track.discNumber)
            add("SampleRate", track.sampleRate); add("Size", track.fileSize); add("BitRate", track.bitrate)
            lines.append("<TRACK " + attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ") + "/>")
        }
        lines.append("</COLLECTION><PLAYLISTS><NODE Type=\"0\" Name=\"ROOT\" Count=\"1\"><NODE Type=\"1\" Name=\"\(escape(snapshot.name))\" KeyType=\"0\" Entries=\"\(snapshot.tracks.count)\">")
        lines += snapshot.tracks.indices.map { "<TRACK Key=\"\($0 + 1)\"/>" }
        lines.append("</NODE></NODE></PLAYLISTS></DJ_PLAYLISTS>")
        return Data(lines.joined(separator: "\n").utf8)
    }
    private static func location(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.host = "localhost"
        return components.url!.absoluteString
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
