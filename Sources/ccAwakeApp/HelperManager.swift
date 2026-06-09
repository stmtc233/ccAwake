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

    func revealInSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setSleepDisabled(_ disabled: Bool, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        invokeHelper(completion: completion) { proxy, reply in
            proxy.setSleepDisabled(disabled, reply: reply)
        }
    }

    func displaySleepNow(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        invokeHelper(completion: completion) { proxy, reply in
            proxy.displaySleepNow(reply)
        }
    }

    /// Runs a Helper call, guaranteeing `completion` fires exactly once.
    ///
    /// XPC failures (daemon not running, connection invalidated) surface
    /// asynchronously via the proxy's error handler rather than the reply
    /// block, and a dead daemon may never call the reply at all. Without the
    /// shared `finish` guard and the timeout, `completion` could be dropped —
    /// leaving the caller hung and never falling back to osascript.
    private func invokeHelper(
        completion: @escaping @Sendable (Result<Void, Error>) -> Void,
        _ body: @escaping (CCAwakeHelperProtocol, @escaping (NSError?) -> Void) -> Void
    ) {
        // Guards against `completion` firing more than once. The reply block,
        // the proxy error handler, and the timeout all race to finish first.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            let completion: (Result<Void, Error>) -> Void
            init(_ completion: @escaping (Result<Void, Error>) -> Void) {
                self.completion = completion
            }
            func finish(_ result: Result<Void, Error>) {
                lock.lock()
                let already = done
                done = true
                lock.unlock()
                guard !already else { return }
                completion(result)
            }
        }

        let once = Once(completion)

        do {
            guard isUsable else {
                throw HelperError.helperUnavailable
            }

            let conn = connection ?? makeConnection()
            connection = conn

            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                once.finish(.failure(HelperError.connectionFailed(error.localizedDescription)))
            } as? CCAwakeHelperProtocol

            guard let proxy else {
                throw HelperError.connectionFailed(L10n.string("helper.castFailed"))
            }

            body(proxy) { error in
                if let error {
                    once.finish(.failure(HelperError.remoteError(error)))
                } else {
                    once.finish(.success(()))
                }
            }

            // Fallback in case neither the reply nor the error handler fires
            // (e.g. the daemon is registered but not actually running).
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                once.finish(.failure(HelperError.helperUnavailable))
            }
        } catch {
            once.finish(.failure(error))
        }
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
