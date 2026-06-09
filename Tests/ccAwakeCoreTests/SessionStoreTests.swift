import XCTest
@testable import ccAwakeCore

final class SessionStoreTests: XCTestCase {
    func testTouchReleaseAndSnapshot() throws {
        let directory = try temporaryDirectory()
        let store = ClaudeSessionStore(
            sessionsURL: directory.appendingPathComponent("sessions.json"),
            lockURL: directory.appendingPathComponent("sessions.lock")
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try store.touch(sessionID: "s1", at: now)

        var snapshot = try store.snapshot(now: now.addingTimeInterval(60), timeout: .minutes(30))
        XCTAssertEqual(snapshot.activeSessions.keys.sorted(), ["s1"])

        try store.release(sessionID: "s1")
        snapshot = try store.snapshot(now: now, timeout: .minutes(30))
        XCTAssertTrue(snapshot.activeSessions.isEmpty)
    }

    func testTimeoutFiltersExpiredSessions() throws {
        let directory = try temporaryDirectory()
        let store = ClaudeSessionStore(
            sessionsURL: directory.appendingPathComponent("sessions.json"),
            lockURL: directory.appendingPathComponent("sessions.lock")
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try store.touch(sessionID: "old", at: now)
        try store.touch(sessionID: "fresh", at: now.addingTimeInterval(1_700))

        let snapshot = try store.snapshot(now: now.addingTimeInterval(1_801), timeout: .minutes(30))
        XCTAssertEqual(snapshot.activeSessions.keys.sorted(), ["fresh"])
    }

    func testNeverTimeoutKeepsSessionsActive() throws {
        let directory = try temporaryDirectory()
        let store = ClaudeSessionStore(
            sessionsURL: directory.appendingPathComponent("sessions.json"),
            lockURL: directory.appendingPathComponent("sessions.lock")
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try store.touch(sessionID: "s1", at: now)

        let snapshot = try store.snapshot(now: now.addingTimeInterval(86_400), timeout: .never)
        XCTAssertEqual(snapshot.activeSessions.keys.sorted(), ["s1"])
    }

    func testHookPayloadParsing() throws {
        let payload = try ClaudeHookPayload.parse(Data(#"{"session_id":"abc"}"#.utf8))
        XCTAssertEqual(payload.sessionID, "abc")
        XCTAssertThrowsError(try ClaudeHookPayload.parse(Data(#"{}"#.utf8)))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccAwake-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
