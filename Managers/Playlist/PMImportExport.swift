//
// PlaylistManager class extension
//
// This extension contains methods for importing and exporting M3U playlists.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Import/Export Result Types

enum M3UImportError: Error, LocalizedError {
    case fileReadFailed(filename: String)
    case invalidFormat(filename: String)
    case emptyFile(filename: String)
    
    var errorDescription: String? {
        switch self {
        case .fileReadFailed(let filename):
            return "Could not read file '\(filename)'"
        case .invalidFormat(let filename):
            return "File '\(filename)' has invalid M3U format"
        case .emptyFile(let filename):
            return "File '\(filename)' contains no tracks"
        }
    }
}

struct PlaylistImportResult {
    let playlistName: String
    let totalTracksInFile: Int
    let tracksAdded: Int
    let tracksMissing: [String]
    let error: Error?
    
    var isSuccess: Bool {
        error == nil && tracksAdded > 0
    }
    
    var hasWarnings: Bool {
        error == nil && !tracksMissing.isEmpty && tracksAdded > 0
    }
    
    var isCompleteFailure: Bool {
        error != nil || (tracksAdded == 0 && totalTracksInFile > 0)
    }
}

struct BulkImportResult {
    let results: [PlaylistImportResult]
    
    var totalFiles: Int { results.count }
    var successful: Int { results.filter { $0.isSuccess && !$0.hasWarnings }.count }
    var withWarnings: Int { results.filter { $0.hasWarnings }.count }
    var failed: Int { results.filter { $0.isCompleteFailure }.count }
    var totalTracksImported: Int { results.reduce(0) { $0 + $1.tracksAdded } }
    var totalTracksMissing: Int { results.reduce(0) { $0 + $1.tracksMissing.count } }
}

struct PlaylistExportResult {
    let playlistName: String
    let error: Error?
    
    var isSuccess: Bool { error == nil }
}

struct BulkExportResult {
    let results: [PlaylistExportResult]
    
    var totalPlaylists: Int { results.count }
    var successful: Int { results.filter { $0.isSuccess }.count }
    var failed: [(playlist: String, error: Error)] {
        results.filter { !$0.isSuccess }.compactMap { result in
            guard let error = result.error else { return nil }
            return (result.playlistName, error)
        }
    }
}

private enum M3UFormat {
    static let header = "#EXTM3U"
    static let infoPrefix = "#EXTINF:"
    static let commentPrefix = "#"
    static let lineEnding = "\r\n"
}

// MARK: - PlaylistManager Extension

extension PlaylistManager {
    // MARK: - Import
    
    func importPlaylists(from urls: [URL]) async -> BulkImportResult {
        let existingNames = await fetchExistingPlaylistNames()
        var usedNames = Set(existingNames.map { $0.lowercased() })
        var results: [PlaylistImportResult] = []
        
        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            let result = await importSinglePlaylist(from: url, usedNames: usedNames)
            results.append(result)
            
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
            
            usedNames.insert(result.playlistName.lowercased())
        }
        
        return BulkImportResult(results: results)
    }
    
    private func fetchExistingPlaylistNames() async -> [String] {
        await MainActor.run { playlists.map { $0.name } }
    }
    
    private func importSinglePlaylist(from url: URL, usedNames: Set<String>) async -> PlaylistImportResult {
        let basePlaylistName = url.deletingPathExtension().lastPathComponent
        let sourceDirectory = url.deletingLastPathComponent()
        
        let fileContent = (try? String(contentsOf: url, encoding: .utf8)) ??
                          (try? String(contentsOf: url, encoding: .isoLatin1))
        
        guard let content = fileContent else {
            Logger.error("Failed to read '\(url.lastPathComponent)' (tried UTF-8 and Latin-1)")
            return PlaylistImportResult(
                playlistName: basePlaylistName,
                totalTracksInFile: 0,
                tracksAdded: 0,
                tracksMissing: [],
                error: M3UImportError.fileReadFailed(filename: url.lastPathComponent)
            )
        }
        
        return await processM3UContent(
            content,
            playlistName: basePlaylistName,
            usedNames: usedNames,
            sourceDirectory: sourceDirectory
        )
    }
    
    private func processM3UContent(
        _ content: String,
        playlistName: String,
        usedNames: Set<String>,
        sourceDirectory: URL? = nil
    ) async -> PlaylistImportResult {
        let trackPaths = parseM3UContent(content)
        
        guard !trackPaths.isEmpty else {
            Logger.error("Empty M3U file: \(playlistName)")
            return PlaylistImportResult(
                playlistName: playlistName,
                totalTracksInFile: 0,
                tracksAdded: 0,
                tracksMissing: [],
                error: M3UImportError.emptyFile(filename: "\(playlistName).m3u")
            )
        }
        
        let matchResult = await matchTracksToLibrary(
            trackPaths: trackPaths,
            sourceDirectory: sourceDirectory
        )
        
        guard !matchResult.matchedTracks.isEmpty else {
            Logger.error("Import failed - '\(playlistName)': 0/\(trackPaths.count) tracks found in library")
            return PlaylistImportResult(
                playlistName: playlistName,
                totalTracksInFile: trackPaths.count,
                tracksAdded: 0,
                tracksMissing: matchResult.unmatchedPaths,
                error: nil
            )
        }
        
        if !matchResult.unmatchedPaths.isEmpty {
            let sample = matchResult.unmatchedPaths.prefix(3).joined(separator: ", ")
            let more = matchResult.unmatchedPaths.count > 3 ? " (+\(matchResult.unmatchedPaths.count - 3) more)" : ""
            let message = """
                Partial import - '\(playlistName)': \(matchResult.matchedTracks.count)/\(trackPaths.count) \
                tracks. Missing: \(sample)\(more)
                """
            Logger.warning(message)
        }
        
        let uniquePlaylistName = generateUniquePlaylistName(baseName: playlistName, existingNames: usedNames)

        // Populate album artwork on matched tracks before creating the playlist
        // so that the collage artwork and gradient are available immediately
        var mutableTracks = matchResult.matchedTracks
        libraryManager?.databaseManager.populateAlbumArtworkForTracks(&mutableTracks)
        let tracksWithArtwork = mutableTracks

        await MainActor.run {
            _ = createPlaylist(name: uniquePlaylistName, tracks: tracksWithArtwork)
        }
        
        return PlaylistImportResult(
            playlistName: uniquePlaylistName,
            totalTracksInFile: trackPaths.count,
            tracksAdded: matchResult.matchedTracks.count,
            tracksMissing: matchResult.unmatchedPaths,
            error: nil
        )
    }
    
    private func parseM3UContent(_ content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(M3UFormat.commentPrefix) }
    }
    
    private func matchTracksToLibrary(
        trackPaths: [String],
        sourceDirectory: URL? = nil
    ) async -> (matchedTracks: [Track], unmatchedPaths: [String]) {
        guard let dbManager = libraryManager?.databaseManager else {
            return ([], trackPaths)
        }
        
        var matchedTracks: [Track] = []
        var unmatchedPaths: [String] = []
        
        for originalPath in trackPaths {
            let pathVariations = generatePathVariations(originalPath, sourceDirectory: sourceDirectory)
            
            var matched = false
            for path in pathVariations {
                if let track = await dbManager.findTrackByPath(path) {
                    matchedTracks.append(track)
                    matched = true
                    break
                }
            }
            
            if !matched {
                unmatchedPaths.append(originalPath)
            }
        }
        
        if !unmatchedPaths.isEmpty {
            let filenames = unmatchedPaths.map { ($0 as NSString).lastPathComponent }
            let filenameMap = await dbManager.findTracksByFilenames(filenames)
            
            var stillUnmatched: [String] = []
            for path in unmatchedPaths {
                let filename = (path as NSString).lastPathComponent.lowercased()
                if let track = filenameMap[filename] {
                    matchedTracks.append(track)
                } else {
                    stillUnmatched.append(path)
                }
            }
            unmatchedPaths = stillUnmatched
        }
        
        return (matchedTracks, unmatchedPaths)
    }
    
    /// Generates possible path variations for M3U import matching
    private func generatePathVariations(_ path: String, sourceDirectory: URL? = nil) -> [String] {
        var normalized = path
        
        for scheme in ["file://", "smb://", "afp://", "nfs://"] where normalized.lowercased().hasPrefix(scheme) {
            normalized = String(normalized.dropFirst(scheme.count))
            break
        }
        
        // Handle Windows-style UNC paths (leading double-slash, e.g. server/share)
        if normalized.hasPrefix("//") {
            normalized = "/Volumes" + String(normalized.dropFirst(1))
        }
        
        normalized = normalized.replacingOccurrences(of: "\\", with: "/")
        
        // URL decode
        normalized = normalized.removingPercentEncoding ?? normalized
        
        var variations = [normalized]
        
        if normalized.hasPrefix("/Volumes/") {
            variations.append(String(normalized.dropFirst(8)))
        } else if normalized.hasPrefix("/") && !normalized.hasPrefix("/Users/") {
            variations.append("/Volumes" + normalized)
        } else if !normalized.hasPrefix("/"), let sourceDirectory {
            var relativePath = normalized
            while relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }
            let resolved = sourceDirectory.appendingPathComponent(relativePath).standardizedFileURL.path
            variations.insert(resolved, at: 0)
        }
        
        return variations
    }
    
    private func generateUniquePlaylistName(baseName: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(baseName.lowercased()) else {
            return baseName
        }
        
        let baseNameLower = baseName.lowercased()
        let highestNumber = existingNames.reduce(1) { currentMax, name in
            guard name.hasPrefix(baseNameLower + " ") else { return currentMax }
            let suffix = String(name.dropFirst(baseNameLower.count + 1))
            return max(currentMax, Int(suffix) ?? 0)
        }
        
        return "\(baseName) \(highestNumber + 1)"
    }
    
    // MARK: - Export
    
    func exportPlaylists(_ playlists: [Playlist], to directoryURL: URL) async -> BulkExportResult {
        var results: [PlaylistExportResult] = []
        
        for playlist in playlists {
            let filename = FilesystemUtils.sanitizeFilename(playlist.name) + ".m3u"
            let fileURL = directoryURL.appendingPathComponent(filename)
            let result = await exportSinglePlaylist(playlist, to: fileURL)
            results.append(result)
        }
        
        return BulkExportResult(results: results)
    }
    
    private func exportSinglePlaylist(_ playlist: Playlist, to fileURL: URL) async -> PlaylistExportResult {
        let tracks = playlist.tracks.isEmpty
            ? await MainActor.run { getPlaylistTracks(playlist) }
            : playlist.tracks
        
        let m3uContent = generateM3UContent(for: tracks)
        
        do {
            try FilesystemUtils.writeM3UFile(content: m3uContent, to: fileURL)
            return PlaylistExportResult(
                playlistName: playlist.name,
                error: nil
            )
        } catch {
            Logger.error("Failed to export '\(playlist.name)': \(error)")
            return PlaylistExportResult(
                playlistName: playlist.name,
                error: error
            )
        }
    }
    
    private func generateM3UContent(for tracks: [Track]) -> String {
        var lines = [M3UFormat.header]
        
        for track in tracks {
            let durationSeconds = Int(track.duration)
            let artistTitle = "\(track.artist) - \(track.title)"
            lines.append("\(M3UFormat.infoPrefix)\(durationSeconds),\(artistTitle)")
            lines.append(track.url.path)
        }
        
        return lines.joined(separator: M3UFormat.lineEnding)
    }
}


// The same snapshot/availability flow serves native menu and bulk-sheet exports.
enum CrateExportFormat: String, CaseIterable {
    case m3u = "M3U", tracklist = "Tracklist", rekordbox = "Rekordbox XML"
    var fileExtension: String { switch self { case .m3u: "m3u"; case .tracklist: "txt"; case .rekordbox: "xml" } }
}

extension PlaylistManager {
    @MainActor
    func prepareExportSnapshot(playlistID: UUID, format: CrateExportFormat) async throws -> CrateExportSnapshot? {
        let snapshot = try await captureExportSnapshot(playlistID: playlistID)
        guard !snapshot.tracks.isEmpty else { throw CrateExportError.empty }
        let available = snapshot.tracks.filter { format == .tracklist ? $0.hasDisplayMetadata : $0.localURL != nil }
        guard available.count != snapshot.tracks.count else { return snapshot }
        let missing = snapshot.tracks.filter { format == .tracklist ? !$0.hasDisplayMetadata : $0.localURL == nil }
        let alert = NSAlert()
        alert.messageText = "Unavailable tracks in \(snapshot.name)"
        alert.informativeText = missing.map { "• " + $0.title }.joined(separator: "\n")
            + "\n\nExport available tracks will export \(available.count) of \(snapshot.tracks.count) tracks."
        alert.addButton(withTitle: "Cancel")
        if !available.isEmpty { alert.addButton(withTitle: "Export available tracks (\(available.count))") }
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        return CrateExportSnapshot(name: snapshot.name, tracks: available)
    }

    @MainActor
    func exportCrate(playlistID: UUID, format: CrateExportFormat, copy: Bool = false) {
        Task { @MainActor in
            do {
                guard let snapshot = try await prepareExportSnapshot(playlistID: playlistID, format: format) else { return }
                var numbered = true
                var includeLabel = false
                if format == .tracklist {
                    let options = NSAlert()
                    options.messageText = copy ? "Copy tracklist" : "Save tracklist"
                    options.addButton(withTitle: "Continue")
                    options.addButton(withTitle: "Cancel")
                    let numbering = NSButton(checkboxWithTitle: "Number tracks", target: nil, action: nil)
                    numbering.state = .on
                    let labels = NSButton(checkboxWithTitle: "Include labels", target: nil, action: nil)
                    let stack = NSStackView(views: [numbering, labels])
                    stack.orientation = .vertical
                    stack.alignment = .leading
                    options.accessoryView = stack
                    guard options.runModal() == .alertFirstButtonReturn else { return }
                    numbered = numbering.state == .on
                    includeLabel = labels.state == .on
                }
                if copy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TracklistFormatter.render(snapshot.tracks, numbered: numbered, includeLabel: includeLabel), forType: .string)
                    NotificationManager.shared.addMessage(.info, "Copied tracklist (\(snapshot.tracks.count) tracks)")
                    return
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = FilesystemUtils.sanitizeFilename(snapshot.name) + "." + format.fileExtension
                panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
                guard await panel.begin() == .OK, let url = panel.url else { return }
                try writeExportSnapshot(snapshot, format: format, to: url, numbered: numbered, includeLabel: includeLabel)
                NotificationManager.shared.addMessage(.info, "Exported \(snapshot.name) (\(snapshot.tracks.count) tracks)")
            } catch { NotificationManager.shared.addMessage(.error, error.localizedDescription) }
        }
    }

    func writeExportSnapshot(_ snapshot: CrateExportSnapshot, format: CrateExportFormat, to url: URL,
                             numbered: Bool = true, includeLabel: Bool = false) throws {
        let data: Data
        switch format {
        case .tracklist:
            data = Data(TracklistFormatter.render(snapshot.tracks, numbered: numbered, includeLabel: includeLabel).utf8)
        case .rekordbox:
            data = try RekordboxExporter.render(snapshot)
        case .m3u:
            var lines = ["#EXTM3U"]
            for track in snapshot.tracks {
                guard let local = track.localURL else { throw CrateExportError.unavailableMedia }
                let duration = track.duration.flatMap { $0.isFinite && $0 >= 0 ? Int(exactly: $0.rounded(.down)) : nil } ?? -1
                lines.append("#EXTINF:\(duration),\(track.artist) - \(track.title)")
                lines.append(local.path)
            }
            data = Data(lines.joined(separator: "\r\n").utf8)
        }
        try data.write(to: url, options: .atomic)
    }
}
