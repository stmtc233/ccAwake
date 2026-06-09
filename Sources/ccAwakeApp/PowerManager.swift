import Foundation
import ccAwakeCore

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

    func setSleepDisabled(
        _ disabled: Bool,
        allowOsascriptFallback: Bool = true,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        if helper.isUsable {
            helper.setSleepDisabled(disabled) { [weak self] result in
                switch result {
                case .success:
                    // The privileged pmset already succeeded — trust it. We do
                    // not re-verify via ioreg and fall back to an admin prompt,
                    // because ioreg's SleepDisabled key can lag the actual value
                    // and would trigger a spurious password dialog.
                    completion(.success(()))
                case .failure(let error):
                    guard allowOsascriptFallback else {
                        completion(.failure(error))
                        return
                    }
                    Task { @MainActor in
                        self?.setSleepDisabledViaOsascript(disabled, completion: completion)
                    }
                }
            }
        } else if allowOsascriptFallback {
            setSleepDisabledViaOsascript(disabled, completion: completion)
        } else {
            completion(.failure(HelperError.helperUnavailable))
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
        // `flag` is a fixed literal, so the command string is constant — no
        // interpolation of dynamic values into the shell/AppleScript string.
        let shellCommand = disabled
            ? "/usr/bin/pmset -a disablesleep 1"
            : "/usr/bin/pmset -a disablesleep 0"
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
            guard let result = ProcessRunner.run(
                executable: executableURL.path,
                arguments: arguments
            ) else {
                completion(.failure(PowerManagerError.launchFailed(ProcessReadError.launchFailed)))
                return
            }

            guard result.status != 0 else {
                completion(.success(()))
                return
            }

            let message = result.stderrString?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(.failure(PowerManagerError.scriptFailed(
                status: result.status,
                message: message
            )))
        }
    }
}
