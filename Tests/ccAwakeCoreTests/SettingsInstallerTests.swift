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
