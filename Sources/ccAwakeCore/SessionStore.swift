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

    public init(sessionID: String) {
        self.sessionID = sessionID
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

        return ClaudeHookPayload(sessionID: rawID)
    }
}

public struct ClaudeSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public var lastActivity: Date

    public init(sessionID: String, lastActivity: Date) {
        self.sessionID = sessionID
        self.lastActivity = lastActivity
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
            document.sessions[sessionID] = ClaudeSession(sessionID: sessionID, lastActivity: date)
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
