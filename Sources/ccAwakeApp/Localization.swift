import Foundation
import ccAwakeCore

enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    static func timeout(_ timeout: SessionTimeout) -> String {
        switch timeout {
        case .minutes(let value):
            return format("timeout.minutes", value)
        case .never:
            return string("timeout.never")
        }
    }
}
