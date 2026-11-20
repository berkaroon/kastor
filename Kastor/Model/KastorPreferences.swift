import Foundation

struct KastorPreferences {
    private static let securityModeKey = "securityMode"
    private static let autoDelete24HoursKey = "autoDelete24Hours"
    private static let languageKey = "appLanguage"
    private static let sizeKey = "historySize"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var securityMode: SecurityMode {
        get {
            guard let raw = defaults.string(forKey: Self.securityModeKey),
                  let mode = SecurityMode(rawValue: raw) else {
                return .sensitive
            }
            return mode
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.securityModeKey)
        }
    }

    var autoDelete24Hours: Bool {
        get {
            guard defaults.object(forKey: Self.autoDelete24HoursKey) != nil else {
                return false
            }
            return defaults.bool(forKey: Self.autoDelete24HoursKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.autoDelete24HoursKey)
        }
    }

    var language: AppLanguage {
        get {
            guard let raw = defaults.string(forKey: Self.languageKey),
                  let lang = AppLanguage(rawValue: raw) else {
                return .en
            }
            return lang
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.languageKey)
        }
    }

    var historySize: Int {
        get {
            let saved = defaults.integer(forKey: Self.sizeKey)
            return [50, 100, 200, 500].contains(saved) ? saved : 100
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.sizeKey)
        }
    }
}
