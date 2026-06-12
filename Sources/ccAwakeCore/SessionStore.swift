import Foundation

public enum ClaudeHookPayloadError: LocalizedError {
    case invalidJSON
    case missingSessionID

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Claude hook payload is not valid JSON."
        case .missingSessionID:
            return "Claude hook payload did not contain session_id."
        }
    }
}

public struct ClaudeHookPayload: Equatable, Sendable {
    public let sessionID: String
    /// The tool being invoked, when present (PreToolUse / PostToolUse payloads).
    public let toolName: String?
    /// The hook event that fired (e.g. "PreToolUse"), when present.
    public let eventName: String?

    public init(sessionID: String, toolName: String? = nil, eventName: String? = nil) {
        self.sessionID = sessionID
        self.toolName = toolName
        self.eventName = eventName
    }

    /// Built-in tools that block waiting for the user to respond. When one of
    /// these is the tool in a `PreToolUse` event, the session is paused awaiting
    /// the user rather than treated as actively working.
    public static let interactiveToolNames: Set<String> = [
        "AskUserQuestion",
        "ExitPlanMode"
    ]

    /// Whether this payload represents Claude pausing on the user via a blocking
    /// interactive tool. Only the `PreToolUse` edge counts: that fires when the
    /// prompt/gate opens. The matching `PostToolUse` fires once the user has
    /// answered, where the session should return to active — so it is excluded.
    public var isInteractiveWait: Bool {
        guard let toolName, Self.interactiveToolNames.contains(toolName) else { return false }
        // When the event name is absent, fall back to treating it as a wait.
        return eventName.map { $0 == "PreToolUse" } ?? true
    }

    public static func parse(_ data: Data) throws -> ClaudeHookPayload {
        guard !data.isEmpty else {
            throw ClaudeHookPayloadError.missingSessionID
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClaudeHookPayloadError.invalidJSON
        }

        guard
            let rawID = object["session_id"] as? String,
            !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ClaudeHookPayloadError.missingSessionID
        }

        let toolName = (object["tool_name"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let eventName = (object["hook_event_name"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return ClaudeHookPayload(sessionID: rawID, toolName: toolName, eventName: eventName)
    }
}

public enum SessionState: String, Codable, Sendable {
    /// Claude is actively working (a tool ran or a prompt was submitted).
    case active
    /// Claude has paused and needs the user to decide something (a permission
    /// prompt, an error, or an idle "needs your attention" notification).
    case waiting
}

public struct ClaudeSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public var lastActivity: Date
    public var state: SessionState

    public init(sessionID: String, lastActivity: Date, state: SessionState = .active) {
        self.sessionID = sessionID
        self.lastActivity = lastActivity
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case lastActivity
        case state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        // Sessions written by older builds have no `state`; treat them as active.
        state = try container.decodeIfPresent(SessionState.self, forKey: .state) ?? .active
    }
}

public struct ClaudeSessionsDocument: Codable, Equatable, Sendable {
    public var sessions: [String: ClaudeSession]

    public init(sessions: [String: ClaudeSession] = [:]) {
        self.sessions = sessions
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public let allSessions: [String: ClaudeSession]
    public let activeSessions: [String: ClaudeSession]

    public init(allSessions: [String: ClaudeSession], activeSessions: [String: ClaudeSession]) {
        self.allSessions = allSessions
        self.activeSessions = activeSessions
    }

    public var hasActiveSessions: Bool {
        !activeSessions.isEmpty
    }

    /// Sessions within the timeout window that are still working.
    public var workingSessions: [String: ClaudeSession] {
        activeSessions.filter { $0.value.state == .active }
    }

    /// Sessions within the timeout window that are paused awaiting the user.
    public var waitingSessions: [String: ClaudeSession] {
        activeSessions.filter { $0.value.state == .waiting }
    }

    public var hasWorkingSessions: Bool {
        !workingSessions.isEmpty
    }

    public var hasWaitingSessions: Bool {
        !waitingSessions.isEmpty
    }
}

public struct ClaudeSessionStore: Sendable {
    public let sessionsURL: URL
    public let lockURL: URL

    public init(paths: CCAwakePaths = CCAwakePaths()) {
        self.sessionsURL = paths.sessionsURL
        self.lockURL = paths.sessionsLockURL
    }

    public init(sessionsURL: URL, lockURL: URL) {
        self.sessionsURL = sessionsURL
        self.lockURL = lockURL
    }

    public func touch(sessionID: String, at date: Date = Date()) throws {
        try mutate { document in
            document.sessions[sessionID] = ClaudeSession(sessionID: sessionID, lastActivity: date, state: .active)
        }
    }

    /// Mark a session as paused and awaiting the user (a permission prompt,
    /// an error, or an idle notification). Keeps the session in the store and
    /// refreshes its activity so the timeout window starts from the pause.
    public func markWaiting(sessionID: String, at date: Date = Date()) throws {
        try mutate { document in
            document.sessions[sessionID] = ClaudeSession(sessionID: sessionID, lastActivity: date, state: .waiting)
        }
    }

    public func release(sessionID: String) throws {
        try mutate { document in
            document.sessions.removeValue(forKey: sessionID)
        }
    }

    public func snapshot(now: Date = Date(), timeout: SessionTimeout) throws -> SessionSnapshot {
        try FileLock(url: lockURL).withExclusiveLock {
            let document = try loadUnlocked()
            let active = document.sessions.filter { _, session in
                guard let interval = timeout.interval else { return true }
                return now.timeIntervalSince(session.lastActivity) <= interval
            }
            return SessionSnapshot(allSessions: document.sessions, activeSessions: active)
        }
    }

    public func pruneExpired(now: Date = Date(), timeout: SessionTimeout) throws {
        guard timeout.interval != nil else { return }

        try mutate { document in
            document.sessions = document.sessions.filter { _, session in
                guard let interval = timeout.interval else { return true }
                return now.timeIntervalSince(session.lastActivity) <= interval
            }
        }
    }

    private func mutate(_ block: (inout ClaudeSessionsDocument) throws -> Void) throws {
        try FileLock(url: lockURL).withExclusiveLock {
            var document = try loadUnlocked()
            try block(&document)
            try saveUnlocked(document)
        }
    }

    private func loadUnlocked() throws -> ClaudeSessionsDocument {
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
            return ClaudeSessionsDocument()
        }

        let data = try Data(contentsOf: sessionsURL)
        if data.isEmpty {
            return ClaudeSessionsDocument()
        }

        return try AtomicJSON.decoder().decode(ClaudeSessionsDocument.self, from: data)
    }

    private func saveUnlocked(_ document: ClaudeSessionsDocument) throws {
        try AtomicJSON.write(document, to: sessionsURL)
    }
}
