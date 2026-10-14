import XCTest
import Foundation
@testable import Petrichor

final class RekordboxExporterTests: XCTestCase, XMLParserDelegate {
    private var collectionTracks: [[String: String]] = []
    private var references: [String] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "TRACK", attributes["Location"] != nil { collectionTracks.append(attributes) }
        if name == "TRACK", let key = attributes["Key"] { references.append(key) }
    }
    func testEscapingRealURLAndTechnicalMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("海 & lumière space.wav")
        // PCM WAV fixture: 48kHz mono, one sample.
        let bytes: [UInt8] = [82,73,70,70,38,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,128,187,0,0,0,119,1,0,2,0,16,0,100,97,116,97,2,0,0,0,0,0]
        try Data(bytes).write(to: file)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let row = ExportTrack(localURL: file, title: "Tune & <海>", artist: "Björk", label: "A&B", sampleRate: 48000, fileSize: Int64(size))
        let data = try RekordboxExporter.render(CrateExportSnapshot(name: "Set & 海", tracks: [row]))
        let parser = XMLParser(data: data)
        parser.delegate = self
        XCTAssertTrue(parser.parse(), "\(String(describing: parser.parserError))")
        XCTAssertEqual(collectionTracks.count, 1)
        XCTAssertEqual(references, [collectionTracks.first?["TrackID"]].compactMap { $0 })
        XCTAssertEqual(collectionTracks.first?["Name"], "Tune & <海>")
        XCTAssertEqual(collectionTracks.first?["SampleRate"], "48000")
        XCTAssertEqual(collectionTracks.first?["Size"], String(size))
        XCTAssertTrue(collectionTracks.first?["Location"]?.hasPrefix("file://localhost/") == true)
        XCTAssertEqual(URL(string: try XCTUnwrap(collectionTracks.first?["Location"]))?.path, file.path)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("44100"))
    }
    func testMissingPathsNeverProduceXML() {
        XCTAssertThrowsError(try RekordboxExporter.render(CrateExportSnapshot(name: "Missing", tracks: [ExportTrack(title: "Missing")])))
    }
}
