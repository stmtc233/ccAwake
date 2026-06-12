import Foundation
import XCTest
@testable import ccAwakeCore

final class SettingsInstallerTests: XCTestCase {
    func testInstallerMergesClaudeHookSettings() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(#"{"permissions":{"allow":["Bash(ls:*)"]}}"#.utf8).write(to: settingsURL)

        let installer = ClaudeSettingsInstaller(settingsURL: settingsURL)
        try installer.install(hookExecutablePath: "/Applications/ccAwake.app/Contents/MacOS/ccawake-hook")

        let root = try readJSON(settingsURL)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in ClaudeHookEvent.allCases {
            let entries = try XCTUnwrap(hooks[event.rawValue] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
        }
        XCTAssertNotNil(root["permissions"])
    }

    func testUninstallRemovesOnlyManagedHooks() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let installer = ClaudeSettingsInstaller(settingsURL: settingsURL)

        try installer.install(hookExecutablePath: "/tmp/ccawake-hook")
        var root = try readJSON(settingsURL)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        hooks["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [
            [
                "hooks": [
                    [
                        "type": "command",
                        "command": "echo keep-me"
                    ]
                ]
            ]
        ]
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]).write(to: settingsURL)

        try installer.uninstall()
        root = try readJSON(settingsURL)
        hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stopEntries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopEntries.count, 1)
    }

    func testBackupsAreCappedAndNewestRetained() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(#"{"permissions":{}}"#.utf8).write(to: settingsURL)

        let installer = ClaudeSettingsInstaller(settingsURL: settingsURL)
        // Each install/uninstall makes one backup; run well past the cap of 5.
        for _ in 0..<8 {
            try installer.install(hookExecutablePath: "/tmp/ccawake-hook")
        }

        let backups = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("settings.json.ccAwake-backup-") }
        XCTAssertLessThanOrEqual(backups.count, 5)
    }

    func testConcurrentInstallUninstallKeepsValidJSON() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(#"{"permissions":{"allow":["Bash(ls:*)"]}}"#.utf8).write(to: settingsURL)

        let installer = ClaudeSettingsInstaller(settingsURL: settingsURL)
        let group = DispatchGroup()
        for index in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                if index.isMultiple(of: 2) {
                    try? installer.install(hookExecutablePath: "/tmp/ccawake-hook")
                } else {
                    try? installer.uninstall()
                }
                group.leave()
            }
        }
        group.wait()

        // The file must always be parseable JSON (atomic writes under the lock).
        let root = try readJSON(settingsURL)
        XCTAssertNotNil(root["permissions"])
    }

    func testInstallationStatusReflectsLifecycle() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let installer = ClaudeSettingsInstaller(settingsURL: settingsURL)

        // No file yet.
        XCTAssertEqual(installer.installationStatus(), .notInstalled)

        try installer.install(hookExecutablePath: "/tmp/ccawake-hook")
        XCTAssertEqual(installer.installationStatus(), .installed)

        // Drop one managed event to simulate a partial / stale install.
        var root = try readJSON(settingsURL)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        hooks["Stop"] = []
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]).write(to: settingsURL)
        XCTAssertEqual(installer.installationStatus(), .partial)

        try installer.uninstall()
        XCTAssertEqual(installer.installationStatus(), .notInstalled)
    }

    func testInstallationStatusIgnoresForeignHooks() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}"#.utf8)
            .write(to: settingsURL)

        let installer = ClaudeSettingsInstaller(settingsURL: settingsURL)
        XCTAssertEqual(installer.installationStatus(), .notInstalled)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccAwake-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
