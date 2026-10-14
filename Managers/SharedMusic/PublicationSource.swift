import Foundation
import CryptoKit
import Darwin
import GRDB

protocol PublicationScopeAccess {
    func access(bookmark: Data, expectedPath: String) throws -> PublicationScopeLease
}
final class PublicationScopeLease {
    let url: URL
    private let release: () -> Void
    init(url: URL, release: @escaping () -> Void = {}) { self.url = url; self.release = release }
    deinit { release() }
}
struct SecurityScopedPublicationAccess: PublicationScopeAccess {
    func access(bookmark: Data, expectedPath: String) throws -> PublicationScopeLease {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
              url.standardizedFileURL.path == URL(fileURLWithPath: expectedPath).standardizedFileURL.path,
              url.startAccessingSecurityScopedResource() else { throw PublicationError.unavailableScope }
        return PublicationScopeLease(url: url) { url.stopAccessingSecurityScopedResource() }
    }
}

final class PublicationSource {
    let journal: PublicationJournal
    private let manager: DatabaseManager
    private let directory: URL
    let scope: any PublicationScopeAccess
    // Test observation seam runs between bounded capture and independent re-read.
    var afterCapture: (() throws -> Void)?
    init(manager: DatabaseManager, snapshotDirectory: URL, scope: any PublicationScopeAccess = SecurityScopedPublicationAccess()) {
        self.manager = manager; self.journal = PublicationJournal(database: manager.dbQueue)
        self.directory = snapshotDirectory; self.scope = scope
    }
    static func components(_ path: String) throws -> [String] {
        let parts = path.components(separatedBy: "/")
        guard !path.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".crate-sync" && !$0.contains("\0") }) else {
            throw PublicationError.invalidDestination
        }
        return parts
    }
    func capture(trackID: Int64, destinationRelativePath: String, confirmedOutsideRootCopy: Bool = false) async throws -> PublicationID {
        try Task.checkCancellation()
        _ = try Self.components(destinationRelativePath)
        guard let pairing = try manager.syncPairing() else { throw PublicationError.unavailableScope }
        try pairing.descriptor.validate()
        let source = try selectedSource(trackID)
        let rootLease = try scope.access(bookmark: pairing.localRootBookmark, expectedPath: pairing.localRootPath)
        let sourceLease = try scope.access(bookmark: source.bookmark, expectedPath: source.folder)
        return try withExtendedLifetime((rootLease, sourceLease)) {
            let prefix = source.folder.hasSuffix("/") ? source.folder : source.folder + "/"
            guard source.path.hasPrefix(prefix) else { throw PublicationError.unavailableSource }
            let relative = String(source.path.dropFirst(prefix.count))
            let rootPrefix = pairing.localRootPath.hasSuffix("/") ? pairing.localRootPath : pairing.localRootPath + "/"
            let inside = source.path.hasPrefix(rootPrefix)
            guard inside || confirmedOutsideRootCopy else { throw PublicationError.needsConfirmation }
            guard !inside || String(source.path.dropFirst(rootPrefix.count)) == destinationRelativePath else { throw PublicationError.invalidDestination }
            let root = try Self.openDirectory(rootLease.url.path)
            defer { close(root) }
            let sourceRoot = try Self.openDirectory(sourceLease.url.path)
            defer { close(sourceRoot) }
            let input = try Self.openRelative(relative, root: sourceRoot)
            defer { close(input) }
            let initial = try Self.identity(input)
            var record = Publication(id: UUID(), trackID: trackID, generation: 1,
                                     snapshot: PublicationSnapshot(trackID: trackID, sourcePath: source.path,
                                      sourceBookmark: source.bookmark, pairing: pairing, sourceIdentity: initial),
                                     destination: destinationRelativePath, state: .capturing)
            try journal.save(record)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let snapshot = directory.appendingPathComponent(record.id.uuidString)
                let output = open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard output >= 0 else { throw PublicationError.storage }
                defer { close(output) }
                let hashes = try Self.stream(input, output: output)
                guard fsync(output) == 0, fchmod(output, 0o400) == 0 else { throw PublicationError.storage }
                let snapshotDirectoryFD = try Self.openDirectory(directory.path)
                defer { close(snapshotDirectoryFD) }
                guard fsync(snapshotDirectoryFD) == 0 else { throw PublicationError.storage }
                try afterCapture?()
                let check = try Self.openRelative(relative, root: sourceRoot)
                defer { close(check) }
                guard try Self.identity(input) == initial, try Self.identity(check) == initial,
                      try Self.stream(check).sha == hashes.sha,
                      try selectedSource(trackID).path == source.path,
                      try manager.syncPairing() == pairing else { throw PublicationError.sourceChanged }
                try Task.checkCancellation()
                let paired: PublicationFileIdentity
                if inside {
                    let existing = try Self.openRelative(destinationRelativePath, root: root)
                    defer { close(existing) }
                    guard try Self.identity(existing) == initial else { throw PublicationError.sourceChanged }
                    paired = initial
                } else {
                    paired = try Self.publishCopy(snapshot: snapshot, destination: destinationRelativePath, root: root, expectedHash: hashes.sha)
                }
                record.snapshot.snapshotPath = snapshot.path
                record.snapshot.sha256 = hashes.sha
                record.snapshot.dropboxHash = hashes.dropbox
                record.snapshot.pairedIdentity = paired
                try verifySourceAndCopy(record)
                try Task.checkCancellation()
                record.state = .queued
                try journal.save(record)
                return record.id
            } catch {
                if error is CancellationError {
                    record.state = .cancelled
                    try journal.save(record)
                    throw CancellationError()
                }
                record.state = .failed
                let failure = (error as? PublicationError) ?? .storage
                record.error = failure
                try journal.save(record)
                throw failure
            }
        }
    }
    func selectedSource(_ id: Int64) throws -> (path: String, folder: String, bookmark: Data) {
        try manager.dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT t.path, f.path AS folder, f.bookmark_data FROM tracks t JOIN folders f ON f.id=t.folder_id WHERE t.id=?", arguments: [id]),
                  let bookmark: Data = row["bookmark_data"] else { throw PublicationError.unavailableSource }
            return (row["path"], row["folder"], bookmark)
        }
    }
    static func identity(_ fd: Int32) throws -> PublicationFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw PublicationError.unavailableSource }
        return PublicationFileIdentity(device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size,
                                       modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                                       changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
    static func openDirectory(_ path: String) throws -> Int32 {
        // Reject symlinks in every component, including the authorized root's ancestors.
        var fd = open("/", O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw PublicationError.unavailableScope }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd); fd = next
            guard fd >= 0 else { throw PublicationError.unavailableScope }
        }
        return fd
    }
    static func openRelative(_ path: String, root: Int32) throws -> Int32 {
        let parts = try components(path)
        var parent = dup(root)
        guard parent >= 0 else { throw PublicationError.storage }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw PublicationError.unavailableSource }
            close(parent); parent = next
        }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw PublicationError.unavailableSource }
        return fd
    }
    static func stream(_ input: Int32, output: Int32? = nil) throws -> (sha: String, dropbox: String) {
        guard lseek(input, 0, SEEK_SET) == 0 else { throw PublicationError.storage }
        var full = SHA256(), blocks = SHA256(), block = SHA256(), blockBytes = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = read(input, &buffer, buffer.count)
            guard count >= 0 else { throw PublicationError.storage }
            if count == 0 { break }
            let data = Data(buffer.prefix(count))
            full.update(data: data)
            var consumed = 0
            while consumed < count {
                let length = min(count - consumed, 4 * 1024 * 1024 - blockBytes)
                block.update(data: data.subdata(in: consumed..<(consumed + length)))
                consumed += length; blockBytes += length
                if blockBytes == 4 * 1024 * 1024 {
                    blocks.update(data: Data(block.finalize())); block = SHA256(); blockBytes = 0
                }
            }
            if let output {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        let written = write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                        guard written > 0 else { throw PublicationError.storage }
                        offset += written
                    }
                }
            }
        }
        if blockBytes > 0 { blocks.update(data: Data(block.finalize())) }
        return (full.finalize().map { String(format: "%02x", $0) }.joined(), blocks.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func publishCopy(snapshot: URL, destination: String, root: Int32, expectedHash: String) throws -> PublicationFileIdentity {
        let parts = try components(destination)
        var parent = dup(root)
        defer { close(parent) }
        for part in parts.dropLast() {
            // Missing directories are not created implicitly: the selected destination must exist.
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw PublicationError.invalidDestination }
            close(parent); parent = next
        }
        // Stage in the pinned destination directory, then atomically link with no overwrite.
        let temporary = ".crate-publication-" + UUID().uuidString
        let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw PublicationError.storage }
        defer { close(output); unlinkat(parent, temporary, 0) }
        let input = open(snapshot.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw PublicationError.integrity }
        defer { close(input) }
        guard try stream(input, output: output).sha == expectedHash, fsync(output) == 0 else { throw PublicationError.integrity }
        if linkat(parent, temporary, parent, parts.last!, 0) != 0 && errno != EEXIST { throw PublicationError.storage }
        let existing = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard existing >= 0 else { throw PublicationError.invalidDestination }
        defer { close(existing) }
        guard try stream(existing).sha == expectedHash else { throw PublicationError.needsNewName }
        guard unlinkat(parent, temporary, 0) == 0 else { throw PublicationError.storage }
        guard fsync(parent) == 0 else { throw PublicationError.storage }
        return try identity(existing)
    }
    /// Upload and mapping owners must call this before consuming local proof.
    func verifySnapshot(_ record: Publication) throws {
        guard record.snapshot.isReady, let path = record.snapshot.snapshotPath else { throw PublicationError.integrity }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw PublicationError.integrity }
        defer { close(fd) }
        let hashes = try Self.stream(fd)
        guard hashes.sha == record.snapshot.sha256, hashes.dropbox == record.snapshot.dropboxHash,
              try Self.identity(fd).size == record.snapshot.sourceIdentity?.size else { throw PublicationError.integrity }
    }
    func verifySourceAndCopy(_ record: Publication) throws {
        try verifySnapshot(record)
        guard try manager.syncPairing() == record.snapshot.pairing,
              try selectedSource(record.trackID).path == record.snapshot.sourcePath else { throw PublicationError.sourceChanged }
        let selected = try selectedSource(record.trackID)
        let prefix = selected.folder.hasSuffix("/") ? selected.folder : selected.folder + "/"
        guard selected.path.hasPrefix(prefix), selected.bookmark == record.snapshot.sourceBookmark else {
            throw PublicationError.sourceChanged
        }
        let sourceLease = try scope.access(bookmark: selected.bookmark, expectedPath: selected.folder)
        let rootLease = try scope.access(bookmark: record.snapshot.pairing.localRootBookmark, expectedPath: record.snapshot.pairing.localRootPath)
        try withExtendedLifetime((sourceLease, rootLease)) {
            let sourceRoot = try Self.openDirectory(sourceLease.url.path)
            defer { close(sourceRoot) }
            let root = try Self.openDirectory(rootLease.url.path)
            defer { close(root) }
            let source = try Self.openRelative(String(selected.path.dropFirst(prefix.count)), root: sourceRoot)
            defer { close(source) }
            let copy = try Self.openRelative(record.destination, root: root)
            defer { close(copy) }
            guard try Self.identity(source) == record.snapshot.sourceIdentity,
                  try Self.stream(source).sha == record.snapshot.sha256,
                  try Self.identity(copy) == record.snapshot.pairedIdentity,
                  try Self.stream(copy).sha == record.snapshot.sha256,
                  try Self.identity(source) == record.snapshot.sourceIdentity,
                  try Self.identity(copy) == record.snapshot.pairedIdentity else { throw PublicationError.sourceChanged }
        }
    }
}
