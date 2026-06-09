import Foundation

enum PowerManagerError: LocalizedError {
    case scriptFailed(status: Int32, message: String)
    case launchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let status, let message):
            if message.isEmpty {
                return L10n.format("power.pmsetFailedStatus", status)
            }
            return L10n.format("power.pmsetFailedMessage", status, message)
        case .launchFailed(let error):
            return L10n.format("power.launchFailed", error.localizedDescription)
        }
    }
}

@MainActor
final class PowerManager {
    private let helper: HelperManager

    init(helper: HelperManager = .shared) {
        self.helper = helper
    }

    func setSleepDisabled(_ disabled: Bool, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        if helper.isUsable {
            helper.setSleepDisabled(disabled) { [weak self] result in
                switch result {
                case .success:
                    completion(.success(()))
                case .failure:
                    Task { @MainActor in
                        self?.setSleepDisabledViaOsascript(disabled, completion: completion)
                    }
                }
            }
        } else {
            setSleepDisabledViaOsascript(disabled, completion: completion)
        }
    }

    func displaySleepNow(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        if helper.isUsable {
            helper.displaySleepNow { [weak self] result in
                switch result {
                case .success:
                    completion(.success(()))
                case .failure:
                    Task { @MainActor in
                        self?.runPMSet(arguments: ["displaysleepnow"], completion: completion)
                    }
                }
            }
        } else {
            runPMSet(arguments: ["displaysleepnow"], completion: completion)
        }
    }

    private func setSleepDisabledViaOsascript(
        _ disabled: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        let flag = disabled ? "1" : "0"
        let shellCommand = "/usr/bin/pmset -a disablesleep \(flag)"
        let appleScript = "do shell script \"\(shellCommand)\" with administrator privileges"
        runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript],
            completion: completion
        )
    }

    private func runPMSet(arguments: [String], completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/pmset"),
            arguments: arguments,
            completion: completion
        )
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
            } catch {
                completion(.failure(PowerManagerError.launchFailed(error)))
                return
            }

            process.waitUntilExit()
            guard process.terminationStatus != 0 else {
                completion(.success(()))
                return
            }

            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(.failure(PowerManagerError.scriptFailed(
                status: process.terminationStatus,
                message: message
            )))
        }
    }
}
