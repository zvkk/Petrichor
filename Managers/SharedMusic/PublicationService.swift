import Foundation
import Darwin

/// One service owns the queue. Waiting callers consume no file buffers or provider sessions.
actor PublicationService {
    static let chunkSize = 8 * 1024 * 1024
    static let maximumSize: UInt64 = (1 << 41) - (1 << 22)
    typealias TransportFactory = (Publication) async throws -> any PublicationTransport
    private let source: PublicationSource
    private let factory: TransportFactory
    private var running = Set<PublicationID>()
    private var cancelled = Set<PublicationID>()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var active = 0

    init(source: PublicationSource, transport: @escaping TransportFactory) {
        self.source = source
        factory = transport
    }
    func cancel(id: PublicationID) throws {
        try source.journal.cancel(id)
        cancelled.insert(id)
    }
    private func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
    private func check(_ record: Publication) throws {
        try Task.checkCancellation()
        guard !cancelled.contains(record.id),
              try source.journal.record(record.id)?.generation == record.generation else { throw PublicationError.cancelled }
    }
    func run(id: PublicationID) async {
        guard running.insert(id).inserted else { return }
        defer { running.remove(id) }
        await acquire()
        defer { release() }
        var claimed: Publication?
        do {
            try Task.checkCancellation()
            guard var record = try source.journal.claim(id) else { return }
            claimed = record
            try check(record)
            guard record.snapshot.isReady, let size = record.snapshot.sourceIdentity?.size,
                  size >= 0, UInt64(size) <= Self.maximumSize else { throw PublicationError.integrity }
            let transport = try await factory(record)
            // A previous finish may have committed even when its response was lost.
            if try await reconcile(record, transport: transport) { return }
            try await verify(record)
            let descriptor = open(record.snapshot.snapshotPath!, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw PublicationError.sourceChanged }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var restarts = 0
            while true {
                try check(record)
                if record.uploadSession == nil {
                    record.uploadSession = PublicationUploadSession(id: try await transport.start(), offset: 0)
                    try transport.checkValidity()
                    try check(record)
                    try source.journal.save(record)
                }
                do {
                    while record.uploadSession!.offset < UInt64(size) {
                        try check(record)
                        let cursor = record.uploadSession!
                        try handle.seek(toOffset: cursor.offset)
                        let remaining = UInt64(size) - cursor.offset
                        let data = try handle.read(upToCount: Int(min(UInt64(Self.chunkSize), remaining))) ?? Data()
                        guard !data.isEmpty else { throw PublicationError.sourceChanged }
                        let end = cursor.offset + UInt64(data.count)
                        let offset = try await transport.append(session: cursor.id, offset: cursor.offset, bytes: data)
                        guard offset == end else { throw PublicationError.integrity }
                        try transport.checkValidity()
                        try check(record)
                        record.uploadSession!.offset = offset
                        try source.journal.save(record)
                    }
                    // Inspect before every finalization, then revalidate all immutable local proof.
                    if try await reconcile(record, transport: transport) { return }
                    try await verify(record)
                    try check(record)
                    record.state = .verifying
                    record.error = .finishUncertain
                    try source.journal.save(record)
                    do { try await transport.finish(session: record.uploadSession!.id, offset: UInt64(size)) }
                    catch {
                        // Explicit cancel does not cancel this metadata read. A committed finish wins.
                        if try await reconcile(record, transport: transport, afterFinish: true) { return }
                        let category = DropboxPublicationTransport.classify(error)
                        if [.quota, .auth, .root, .sessionExpired, .needsNewName, .contentMismatch].contains(category) {
                            try source.journal.rejectFinish(record, error: category)
                            record.error = category
                        }
                        throw error
                    }
                    guard try await reconcile(record, transport: transport, afterFinish: true) else {
                        throw PublicationError.retryable
                    }
                    return
                } catch PublicationError.sessionExpired {
                    if try await reconcile(record, transport: transport) { return }
                    guard restarts < 1 else { throw PublicationError.retryable }
                    restarts += 1
                    record.uploadSession = nil
                    record.state = .uploading
                    record.error = nil
                    try source.journal.save(record)
                }
            }
        } catch {
            guard var record = claimed,
                  let current = try? source.journal.record(id), current.generation == record.generation,
                  current.state != .completed else { return }
            record = current
            let isCancelled = error is CancellationError || cancelled.contains(id)
            let category = DropboxPublicationTransport.classify(error)
            if record.error == .finishUncertain && ![.contentMismatch, .needsNewName].contains(category) {
                record.state = isCancelled ? .cancelled : .verifying
                // Durable uncertainty survives network/auth failures and process death.
            } else {
                record.state = isCancelled ? .cancelled : .failed
                record.error = error is CancellationError ? .cancelled : DropboxPublicationTransport.classify(error)
            }
            try? source.journal.save(record)
        }
    }
    /// Explicit outcome check. Never claims, starts, resumes, appends, or finishes an upload.
    func reconcileOutcome(id: PublicationID) async throws {
        guard running.insert(id).inserted else { return }
        defer { running.remove(id) }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard var record = try source.journal.record(id), record.state != .completed,
              record.state == .cancelled || record.error == .finishUncertain else { return }
        let transport = try await factory(record)
        if try await reconcile(record, transport: transport, afterFinish: true) { return }
        try transport.checkValidity()
        // A successful exact lookup confirmed absence; cancellation stays cancelled.
        record.state = .cancelled
        record.error = .cancelled
        try source.journal.save(record)
    }
    private func verify(_ record: Publication) async throws {
        let source = source
        try await Task.detached { try source.verifySourceAndCopy(record) }.value
    }
    private func reconcile(_ record: Publication, transport: any PublicationTransport, afterFinish: Bool = false) async throws -> Bool {
        guard let remote = try await transport.metadataAtDestination() else { return false }
        guard remote.size == UInt64(record.snapshot.sourceIdentity!.size), remote.contentHash == record.snapshot.dropboxHash else {
            throw afterFinish ? PublicationError.contentMismatch : PublicationError.needsNewName
        }
        guard remote.fileID.hasPrefix("id:"), remote.fileID.count > 3 else { throw PublicationError.contentMismatch }
        try await verify(record)
        try transport.checkValidity()
        try source.journal.complete(record, proof: remote, allowingCancellation: afterFinish)
        return true
    }
}
