import Foundation

public enum SessionTimeout: Codable, Equatable, Sendable {
    case minutes(Int)
    case never

    public var interval: TimeInterval? {
        switch self {
        case .minutes(let value):
            return TimeInterval(max(1, value) * 60)
        case .never:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .minutes(let value):
            return "\(value) minutes"
        case .never:
            return "Never"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case minutes
    }

    private enum Kind: String, Codable {
        case minutes
        case never
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .minutes:
            self = .minutes(try container.decode(Int.self, forKey: .minutes))
        case .never:
            self = .never
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .minutes(let value):
            try container.encode(Kind.minutes, forKey: .kind)
            try container.encode(value, forKey: .minutes)
        case .never:
            try container.encode(Kind.never, forKey: .kind)
        }
    }
}

public struct CCAwakeSettings: Codable, Equatable, Sendable {
    public var allowOnBattery: Bool
    public var timeout: SessionTimeout
    public var manualKeepAwake: Bool
    public var automationEnabled: Bool

    public init(
        allowOnBattery: Bool = false,
        timeout: SessionTimeout = .minutes(30),
        manualKeepAwake: Bool = false,
        automationEnabled: Bool = true
    ) {
        self.allowOnBattery = allowOnBattery
        self.timeout = timeout
        self.manualKeepAwake = manualKeepAwake
        self.automationEnabled = automationEnabled
    }

    public static let `default` = CCAwakeSettings()
}

public struct SettingsStore: Sendable {
    public let settingsURL: URL

    public init(paths: CCAwakePaths = CCAwakePaths()) {
        self.settingsURL = paths.settingsURL
    }

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public func load() throws -> CCAwakeSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .default
        }

        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty {
            return .default
        }

        return try AtomicJSON.decoder().decode(CCAwakeSettings.self, from: data)
    }

    public func save(_ settings: CCAwakeSettings) throws {
        try AtomicJSON.write(settings, to: settingsURL)
    }
}
