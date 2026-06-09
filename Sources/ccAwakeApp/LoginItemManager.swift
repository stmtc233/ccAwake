import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case notRegistered
    case awaitingApproval
    case enabled
    case notFound
}

@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private let service = SMAppService.mainApp

    private init() {}

    var state: LoginItemState {
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

    var isEnabled: Bool {
        state == .enabled
    }

    func toggle() throws {
        switch state {
        case .enabled:
            try service.unregister()
        case .awaitingApproval:
            revealInSystemSettings()
        case .notRegistered, .notFound:
            try service.register()
        }
    }

    func revealInSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
