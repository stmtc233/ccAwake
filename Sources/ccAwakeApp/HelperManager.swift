import Foundation
import ServiceManagement
import AppKit
import ccAwakeCore

enum HelperState: Equatable {
    case notRegistered
    case awaitingApproval
    case enabled
    case notFound
}

enum HelperError: LocalizedError {
    case helperUnavailable
    case connectionFailed(String)
    case remoteError(Error)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return L10n.string("helper.unavailable")
        case .connectionFailed(let detail):
            return L10n.format("helper.connectionFailed", detail)
        case .remoteError(let error):
            return error.localizedDescription
        }
    }
}

@MainActor
final class HelperManager {
    static let shared = HelperManager()

    private let service: SMAppService
    private var connection: NSXPCConnection?

    private init() {
        service = SMAppService.daemon(plistName: CCAwakeHelperConstants.plistName)
    }

    var state: HelperState {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .awaitingApproval
        case .enabled:
            return .enabled
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    var isUsable: Bool {
        state == .enabled
    }

    func register() {
        do {
            try service.register()
        } catch {
            NSLog("ccAwake: SMAppService.register() failed: \(error.localizedDescription)")
        }
    }

    func unregister() {
        do {
            try service.unregister()
        } catch {
            NSLog("ccAwake: SMAppService.unregister() failed: \(error.localizedDescription)")
        }
    }

    func revealInSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setSleepDisabled(_ disabled: Bool, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        do {
            let proxy = try ensureProxy()
            proxy.setSleepDisabled(disabled) { error in
                if let error {
                    completion(.failure(HelperError.remoteError(error)))
                } else {
                    completion(.success(()))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    func displaySleepNow(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        do {
            let proxy = try ensureProxy()
            proxy.displaySleepNow { error in
                if let error {
                    completion(.failure(HelperError.remoteError(error)))
                } else {
                    completion(.success(()))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func ensureProxy() throws -> CCAwakeHelperProtocol {
        guard isUsable else {
            throw HelperError.helperUnavailable
        }

        let conn = connection ?? makeConnection()
        connection = conn

        var proxyError: Error?
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            proxyError = error
        } as? CCAwakeHelperProtocol

        if let proxyError {
            connection?.invalidate()
            connection = nil
            throw HelperError.connectionFailed(proxyError.localizedDescription)
        }

        guard let proxy else {
            throw HelperError.connectionFailed(L10n.string("helper.castFailed"))
        }

        return proxy
    }

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(
            machServiceName: CCAwakeHelperConstants.machServiceName,
            options: .privileged
        )
        conn.remoteObjectInterface = NSXPCInterface(with: CCAwakeHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
            }
        }
        conn.resume()
        return conn
    }
}
