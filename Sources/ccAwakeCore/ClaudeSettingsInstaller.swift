import Foundation

public enum ClaudeHookEvent: String, CaseIterable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case notification = "Notification"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"

    public var hookAction: String {
        switch self {
        case .userPromptSubmit, .preToolUse, .postToolUse:
            return "touch"
        case .notification, .stop, .sessionEnd:
            return "release"
        }
    }
}

public enum ClaudeSettingsInstallerError: LocalizedError {
    case rootIsNotDictionary
    case couldNotSerialize

    public var errorDescription: String? {
        switch self {
        case .rootIsNotDictionary:
            return "Claude settings root JSON value is not an object."
        case .couldNotSerialize:
            return "Could not serialize Claude settings JSON."
        }
    }
}

public struct ClaudeSettingsInstaller: Sendable {
    public let settingsURL: URL
    public let lockURL: URL

    /// Number of timestamped backups to retain; older ones are pruned.
    private static let maxBackups = 5

    public init(
        settingsURL: URL = ClaudeSettingsInstaller.defaultSettingsURL(),
        lockURL: URL? = nil
    ) {
        self.settingsURL = settingsURL
        self.lockURL = lockURL ?? settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json.ccAwake-lock")
    }

    public static func defaultSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func install(hookExecutablePath: String) throws {
        // Serialize ccAwake's own read-modify-write under an advisory lock and
        // write atomically. This does not force Claude Code (which owns this
        // file) to cooperate, but it prevents concurrent ccAwake installs from
        // racing and keeps the file always-valid via the atomic replace.
        try FileLock(url: lockURL).withExclusiveLock {
            var root = try readRoot()
            try backupIfPresent()

            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in ClaudeHookEvent.allCases {
                let currentEntries = hooks[event.rawValue] as? [[String: Any]] ?? []
                let cleaned = currentEntries.filter { !Self.containsManagedCommand($0) }
                hooks[event.rawValue] = cleaned + [Self.entry(for: event, hookExecutablePath: hookExecutablePath)]
            }

            root["hooks"] = hooks
            try writeRoot(root)
        }
    }

    public func uninstall() throws {
        try FileLock(url: lockURL).withExclusiveLock {
            var root = try readRoot()
            try backupIfPresent()

            guard var hooks = root["hooks"] as? [String: Any] else {
                try writeRoot(root)
                return
            }

            for event in ClaudeHookEvent.allCases {
                guard let entries = hooks[event.rawValue] as? [[String: Any]] else { continue }
                hooks[event.rawValue] = entries.filter { !Self.containsManagedCommand($0) }
            }

            root["hooks"] = hooks
            try writeRoot(root)
        }
    }

    public static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func entry(for event: ClaudeHookEvent, hookExecutablePath: String) -> [String: Any] {
        [
            "hooks": [
                [
                    "type": "command",
                    "command": "\(shellQuoted(hookExecutablePath)) \(event.hookAction)"
                ]
            ]
        ]
    }

    private static func containsManagedCommand(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else {
            return false
        }

        return hooks.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.contains("ccawake-hook")
        }
    }

    private func readRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty {
            return [:]
        }

        let value = try JSONSerialization.jsonObject(with: data)
        guard let root = value as? [String: Any] else {
            throw ClaudeSettingsInstallerError.rootIsNotDictionary
        }
        return root
    }

    private func writeRoot(_ root: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw ClaudeSettingsInstallerError.couldNotSerialize
        }

        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func backupIfPresent() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: Date())
        let backupURL = settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json.ccAwake-backup-\(timestamp)-\(UUID().uuidString)")

        try FileManager.default.copyItem(at: settingsURL, to: backupURL)
        pruneBackups(keeping: Self.maxBackups)
    }

    /// Best-effort pruning of old backups, keeping the most recent `count`.
    /// The `yyyyMMddHHmmss` prefix sorts lexicographically in chronological
    /// order; pruning failure must never fail an install/uninstall.
    private func pruneBackups(keeping count: Int) {
        let directory = settingsURL.deletingLastPathComponent()
        let prefix = "settings.json.ccAwake-backup-"

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }

        let backups = names
            .filter { $0.hasPrefix(prefix) }
            .sorted(by: >)

        guard backups.count > count else { return }
        for name in backups.dropFirst(count) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
