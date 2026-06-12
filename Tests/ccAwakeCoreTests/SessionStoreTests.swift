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

    func testMarkWaitingSetsStateAndSeparatesSnapshots() throws {
        let directory = try temporaryDirectory()
        let store = ClaudeSessionStore(
            sessionsURL: directory.appendingPathComponent("sessions.json"),
            lockURL: directory.appendingPathComponent("sessions.lock")
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try store.touch(sessionID: "working", at: now)
        try store.markWaiting(sessionID: "paused", at: now)

        let snapshot = try store.snapshot(now: now.addingTimeInterval(60), timeout: .minutes(30))
        XCTAssertTrue(snapshot.hasWorkingSessions)
        XCTAssertTrue(snapshot.hasWaitingSessions)
        XCTAssertEqual(snapshot.workingSessions.keys.sorted(), ["working"])
        XCTAssertEqual(snapshot.waitingSessions.keys.sorted(), ["paused"])
    }

    func testTouchAfterWaitingReturnsToActive() throws {
        let directory = try temporaryDirectory()
        let store = ClaudeSessionStore(
            sessionsURL: directory.appendingPathComponent("sessions.json"),
            lockURL: directory.appendingPathComponent("sessions.lock")
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try store.markWaiting(sessionID: "s1", at: now)
        try store.touch(sessionID: "s1", at: now.addingTimeInterval(1))

        let snapshot = try store.snapshot(now: now.addingTimeInterval(2), timeout: .minutes(30))
        XCTAssertTrue(snapshot.hasWorkingSessions)
        XCTAssertFalse(snapshot.hasWaitingSessions)
    }

    func testLegacySessionWithoutStateDecodesAsActive() throws {
        let json = #"{"sessions":{"s1":{"sessionID":"s1","lastActivity":0}}}"#
        let document = try AtomicJSON.decoder().decode(ClaudeSessionsDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.sessions["s1"]?.state, .active)
    }

    func testHookPayloadParsing() throws {
        let payload = try ClaudeHookPayload.parse(Data(#"{"session_id":"abc"}"#.utf8))
        XCTAssertEqual(payload.sessionID, "abc")
        XCTAssertThrowsError(try ClaudeHookPayload.parse(Data(#"{}"#.utf8)))
    }

    func testInteractiveWaitOnlyForPreToolUseOfInteractiveTools() throws {
        let preAsk = try ClaudeHookPayload.parse(Data(
            #"{"session_id":"s","tool_name":"AskUserQuestion","hook_event_name":"PreToolUse"}"#.utf8))
        XCTAssertTrue(preAsk.isInteractiveWait)

        let prePlan = try ClaudeHookPayload.parse(Data(
            #"{"session_id":"s","tool_name":"ExitPlanMode","hook_event_name":"PreToolUse"}"#.utf8))
        XCTAssertTrue(prePlan.isInteractiveWait)

        // The answer arrives via PostToolUse — session should go back to active.
        let postAsk = try ClaudeHookPayload.parse(Data(
            #"{"session_id":"s","tool_name":"AskUserQuestion","hook_event_name":"PostToolUse"}"#.utf8))
        XCTAssertFalse(postAsk.isInteractiveWait)

        // Ordinary tools never count as interactive waits.
        let bash = try ClaudeHookPayload.parse(Data(
            #"{"session_id":"s","tool_name":"Bash","hook_event_name":"PreToolUse"}"#.utf8))
        XCTAssertFalse(bash.isInteractiveWait)

        // No tool name (e.g. UserPromptSubmit) is not a wait.
        let prompt = try ClaudeHookPayload.parse(Data(#"{"session_id":"s"}"#.utf8))
        XCTAssertFalse(prompt.isInteractiveWait)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccAwake-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
