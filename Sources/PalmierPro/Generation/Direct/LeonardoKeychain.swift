import Foundation

extension Notification.Name {
    static let leonardoAPIKeyChanged = Notification.Name("leonardoAPIKeyChanged")
}

enum LeonardoKeychain {
    private static let account = "leonardo-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .leonardoAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["LEONARDO_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .leonardoAPIKeyChanged, object: nil)
    }
}
