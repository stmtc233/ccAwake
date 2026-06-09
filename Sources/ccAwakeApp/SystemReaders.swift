import Foundation

enum ProcessReadError: Error {
    case launchFailed
}

enum CommandReader {
    static func read(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
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
}

enum SleepDisabledReader {
    static func isSleepDisabled() -> Bool? {
        guard let output = CommandReader.read(
            executable: "/usr/sbin/ioreg",
            arguments: ["-r", "-k", "SleepDisabled", "-d", "4"]
        ) else {
            return nil
        }

        if output.contains("\"SleepDisabled\" = Yes") {
            return true
        }
        if output.contains("\"SleepDisabled\" = No") {
            return false
        }
        return nil
    }

    static func verify(
        expected: Bool,
        attempts: Int = 6,
        interval: TimeInterval = 0.25,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            for attempt in 0..<attempts {
                if isSleepDisabled() == expected {
                    completion(true)
                    return
                }
                if attempt + 1 < attempts {
                    Thread.sleep(forTimeInterval: interval)
                }
            }
            completion(false)
        }
    }
}
