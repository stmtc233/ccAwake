import Foundation
import ccAwakeCore

enum ProcessReadError: Error {
    case launchFailed
}

enum CommandReader {
    static func read(executable: String, arguments: [String]) -> String? {
        guard let result = ProcessRunner.run(executable: executable, arguments: arguments) else {
            return nil
        }
        guard result.status == 0 else { return nil }
        return result.stdoutString
    }
}

enum PowerSourceReader {
    static func isOnACPower() -> Bool? {
        guard let output = CommandReader.read(executable: "/usr/bin/pmset", arguments: ["-g", "batt"]) else {
            return nil
        }

        if output.contains("AC Power") {
            return true
        }
        if output.contains("Battery Power") {
            return false
        }
        return nil
    }

    /// Off-main-thread variant: spawns `pmset` on a background queue so the
    /// caller (e.g. the @MainActor evaluate loop) never blocks on the subprocess.
    static func readIsOnACPower(completion: @escaping @Sendable (Bool?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(isOnACPower())
        }
    }
}

enum ClamshellReader {
    static func isLidClosed() -> Bool? {
        guard let output = CommandReader.read(
            executable: "/usr/sbin/ioreg",
            arguments: ["-r", "-k", "AppleClamshellState", "-d", "4"]
        ) else {
            return nil
        }

        if output.contains("\"AppleClamshellState\" = Yes") {
            return true
        }
        if output.contains("\"AppleClamshellState\" = No") {
            return false
        }
        return nil
    }

    /// Off-main-thread variant; see `PowerSourceReader.readIsOnACPower`.
    static func readIsLidClosed(completion: @escaping @Sendable (Bool?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(isLidClosed())
        }
    }
}
