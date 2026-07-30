import Foundation

extension Notification.Name {
    static let vastAIAPIKeyChanged = Notification.Name("vastAIAPIKeyChanged")
}

enum VastAIKeychain {
    private static let account = "vast-ai-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .vastAIAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["VAST_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .vastAIAPIKeyChanged, object: nil)
    }
}
