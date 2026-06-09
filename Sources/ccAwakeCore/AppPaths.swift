import Foundation

public struct CCAwakePaths: Equatable, Sendable {
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL = CCAwakePaths.defaultApplicationSupportDirectory()) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var sessionsURL: URL {
        applicationSupportDirectory.appendingPathComponent("sessions.json")
    }

    public var sessionsLockURL: URL {
        applicationSupportDirectory.appendingPathComponent("sessions.lock")
    }

    public var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("settings.json")
    }

    public static func defaultApplicationSupportDirectory() -> URL {
        if
            let override = ProcessInfo.processInfo.environment["CCAWAKE_APP_SUPPORT_DIR"],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ccAwake", isDirectory: true)
    }

    public func ensureApplicationSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
    }
}
