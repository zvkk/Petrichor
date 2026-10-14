import Foundation
import XCTest
@testable import Petrichor

private final class PublicationFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let (status, data) = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class PublicationTransportTests: XCTestCase {
    override func tearDown() { PublicationFixtureProtocol.handler = nil }
    func client() -> DropboxPlaylistTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PublicationFixtureProtocol.self]
        return DropboxPlaylistTransport(accessToken: "fixture", namespace: "pinned", session: URLSession(configuration: config))
    }
    func testNativeSessionUsesPinnedScopeAndStrictNoOverwriteCommit() async throws {
        var endpoints: [String] = []
        PublicationFixtureProtocol.handler = { request in
            endpoints.append(request.url!.lastPathComponent)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Dropbox-API-Path-Root"))
            let raw = try XCTUnwrap(request.value(forHTTPHeaderField: "Dropbox-API-Arg"))
            XCTAssertTrue(raw.unicodeScalars.allSatisfy { $0.isASCII })
            let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            if let commit = args["commit"] as? [String: Any] {
                XCTAssertEqual(commit["path"] as? String, "id:music/café.wav")
                XCTAssertEqual(commit["autorename"] as? Bool, false)
                XCTAssertEqual(commit["strict_conflict"] as? Bool, true)
                XCTAssertEqual((commit["mode"] as? [String: String])?[".tag"], "add")
            }
            return (200, Data("{\"session_id\":\"opaque\"}".utf8))
        }
        let transport = DropboxPublicationTransport(client: client(), destination: "id:music/café.wav", expectedPath: "/music/café.wav", validate: {})
        let session = try await transport.start()
        let offset = try await transport.append(session: session, offset: 0, bytes: Data("audio".utf8))
        try await transport.finish(session: session, offset: offset)
        XCTAssertEqual(endpoints, ["start", "append_v2", "finish"])
    }
    func testNativeAppendAcceptsOnlyExactConfirmedChunkEnd() async throws {
        var confirmed: UInt64 = 5
        PublicationFixtureProtocol.handler = { _ in
            (409, try JSONSerialization.data(withJSONObject: ["error_summary": "incorrect_offset/", "error": [".tag": "incorrect_offset", "correct_offset": confirmed]]))
        }
        let transport = DropboxPublicationTransport(client: client(), destination: "id:music/a.wav", expectedPath: "/music/a.wav", validate: {})
        let offset = try await transport.append(session: "opaque", offset: 0, bytes: Data(repeating: 1, count: 5))
        XCTAssertEqual(offset, 5)
        confirmed = 3
        do { _ = try await transport.append(session: "opaque", offset: 0, bytes: Data(repeating: 1, count: 5)); XCTFail() }
        catch { XCTAssertEqual(error as? PublicationError, .retryable) }
    }
    func testNativeErrorsAreSanitizedAndInvalidationStopsNetwork() async throws {
        var count = 0
        var status = 401
        var summary = "secret provider body"
        PublicationFixtureProtocol.handler = { _ in
            count += 1
            return (status, try JSONSerialization.data(withJSONObject: ["error_summary": summary]))
        }
        let native = client()
        let epoch = PublicationConnectionEpoch()
        let captured = epoch.current()
        let transport = DropboxPublicationTransport(client: native, destination: "id:music/a.wav", expectedPath: "/music/a.wav", validate: {
            guard epoch.current() == captured else { throw PublicationError.auth }
        })
        for (code, text, expected): (Int, String, PublicationError) in [(401, "secret", .auth), (409, "path/insufficient_space", .quota), (422, "secret", .root), (500, "secret", .retryable), (409, "not_found/", .sessionExpired)] {
            status = code; summary = text
            do { _ = try await transport.start(); XCTFail() } catch { XCTAssertEqual(error as? PublicationError, expected) }
        }
        epoch.invalidate()
        do { _ = try await transport.start(); XCTFail() } catch { XCTAssertEqual(error as? PublicationError, .auth) }
        XCTAssertEqual(count, 5)
    }
    func testMetadataRejectsWrongPathAndReusesOnlyRealProof() async throws {
        var path = "/elsewhere/a.wav"
        PublicationFixtureProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [".tag": "file", "id": "id:real", "size": 7, "content_hash": String(repeating: "a", count: 64), "path_lower": path]))
        }
        let transport = DropboxPublicationTransport(client: client(), destination: "id:music/a.wav", expectedPath: "/music/a.wav", validate: {})
        do { _ = try await transport.metadataAtDestination(); XCTFail() } catch { XCTAssertEqual(error as? PublicationError, .contentMismatch) }
        path = "/music/a.wav"
        let proof = try await transport.metadataAtDestination()
        XCTAssertEqual(proof?.fileID, "id:real")
    }
    func testDisconnectDuringResponseRejectsSuccessfulAppendAcknowledgement() async throws {
        let epoch = PublicationConnectionEpoch()
        let captured = epoch.current()
        PublicationFixtureProtocol.handler = { _ in
            epoch.invalidate()
            return (200, Data())
        }
        let transport = DropboxPublicationTransport(client: client(), destination: "id:music/a.wav", expectedPath: "/music/a.wav", validate: {
            guard epoch.current() == captured else { throw PublicationError.auth }
        })
        do { _ = try await transport.append(session: "opaque", offset: 0, bytes: Data([1])); XCTFail() }
        catch { XCTAssertEqual(error as? PublicationError, .auth) }
    }

}
