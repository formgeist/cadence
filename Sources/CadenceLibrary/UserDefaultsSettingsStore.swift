import Foundation
import CadenceCore

/// The `SettingsStore` the app actually ships with — see #42. Everything
/// else (`InMemorySettingsStore`) exists so previews and tests don't have to
/// touch the user's real defaults.
@MainActor
public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "Cadence.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    private func key(_ key: SettingsKey) -> String { prefix + key.rawValue }

    public func double(forKey key: SettingsKey) -> Double? {
        let k = self.key(key)
        guard defaults.object(forKey: k) != nil else { return nil }
        return defaults.double(forKey: k)
    }

    public func set(_ value: Double?, forKey key: SettingsKey) {
        let k = self.key(key)
        if let value {
            defaults.set(value, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }

    public func bool(forKey key: SettingsKey) -> Bool? {
        let k = self.key(key)
        guard defaults.object(forKey: k) != nil else { return nil }
        return defaults.bool(forKey: k)
    }

    public func set(_ value: Bool?, forKey key: SettingsKey) {
        let k = self.key(key)
        if let value {
            defaults.set(value, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }

    public func string(forKey key: SettingsKey) -> String? {
        defaults.string(forKey: self.key(key))
    }

    public func set(_ value: String?, forKey key: SettingsKey) {
        let k = self.key(key)
        if let value {
            defaults.set(value, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }
}
