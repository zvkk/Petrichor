import Foundation

typealias PublicationID = UUID

enum PublicationState: String, Codable, CaseIterable, Sendable {
    case queued, capturing, uploading, verifying, completed, cancelled, failed
}

enum PublicationError: String, Error, Codable, Sendable {
    case invalidDestination, unavailableSource, unavailableScope, sourceChanged, needsConfirmation
    case needsNewName, integrity, invalidTransition, storage
    case contentMismatch, auth, root, quota, retryable, cancelled, sessionExpired, finishUncertain
}

struct PublicationFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

struct PublicationSnapshot: Codable, Equatable, Sendable {
    let trackID: Int64
    let sourcePath: String
    let sourceBookmark: Data
    let pairing: SyncPairing
    var sourceIdentity: PublicationFileIdentity?
    var snapshotPath: String?
    var sha256: String?
    var dropboxHash: String?
    var pairedIdentity: PublicationFileIdentity?
    var isReady: Bool {
        sourceIdentity != nil && snapshotPath != nil && sha256 != nil && dropboxHash != nil && pairedIdentity != nil
    }
}

struct PublicationUploadSession: Codable, Equatable, Sendable {
    var id: String
    var offset: UInt64
}
struct PublicationRemoteProof: Codable, Equatable, Sendable {
    var fileID: String
    var contentHash: String
    var size: UInt64
}
struct Publication: Equatable, Sendable {
    let id: PublicationID
    let trackID: Int64
    let generation: Int64
    var snapshot: PublicationSnapshot
    let destination: String
    var state: PublicationState
    var uploadSession: PublicationUploadSession?
    var verifiedMapping: PublicationRemoteProof?
    var error: PublicationError?
}
