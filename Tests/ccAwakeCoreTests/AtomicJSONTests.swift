import Foundation
import XCTest
@testable import ccAwakeCore

final class AtomicJSONTests: XCTestCase {
    func testWriteThenReadRoundTrips() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("doc.json")

        let document = ClaudeSessionsDocument(sessions: [
            "a": ClaudeSession(sessionID: "a", lastActivity: Date(timeIntervalSince1970: 1000))
        ])
        try AtomicJSON.write(document, to: url)

        let data = try Data(contentsOf: url)
        let decoded = try AtomicJSON.decoder().decode(ClaudeSessionsDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertTrue(temporaryFiles(in: directory).isEmpty, "no temp files should remain")
    }

    func testFailedWriteLeavesNoTempFile() throws {
        let directory = try temporaryDirectory()
        // Destination is a non-empty, unreadable directory. The temp file is
        // written into the (writable) parent, but replaceItemAt/moveItem onto
        // the destination fails — exercising the catch-path cleanup.
        let url = directory.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("child"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }

        let document = ClaudeSessionsDocument()
        XCTAssertThrowsError(try AtomicJSON.write(document, to: url))

        let leftovers = temporaryFiles(in: directory)
        XCTAssertTrue(leftovers.isEmpty, "temp file should be cleaned up on failure, found: \(leftovers)")
    }

    private func temporaryFiles(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.contains(".tmp-") }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccAwake-atomicjson-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
