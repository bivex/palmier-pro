import Foundation

extension Notification.Name {
    static let falAIAPIKeyChanged = Notification.Name("falAIAPIKeyChanged")
    static let klingAPIKeyChanged = Notification.Name("klingAPIKeyChanged")
}

enum FalAIKeychain {
    private static let account = "fal-ai-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .falAIAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["FAL_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["FAL_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .falAIAPIKeyChanged, object: nil)
    }
}

enum KlingKeychain {
    private static let account = "kling-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .klingAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["KLING_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .klingAPIKeyChanged, object: nil)
    }
}

enum DirectKeyStore {
    static var hasGoogleKey: Bool { GoogleAIKeychain.load() != nil }
    static var hasFalKey: Bool { FalAIKeychain.load() != nil }
    static var hasKlingKey: Bool { KlingKeychain.load() != nil }
    static var hasLeonardoKey: Bool { LeonardoKeychain.load() != nil }
    static var hasVastKey: Bool { VastAIKeychain.load() != nil }

    static var hasAnyDirectKey: Bool {
        hasGoogleKey || hasFalKey || hasKlingKey || hasLeonardoKey || hasVastKey
    }

    static func hasKey(for modelId: String) -> Bool {
        let id = modelId.lowercased()
        if id.contains("google") || id.contains("gemini") || id.contains("imagen") || id.contains("banana") {
            return hasGoogleKey
        }
        if id.contains("kling") {
            return hasKlingKey || hasFalKey
        }
        if id.contains("leonardo") {
            return hasLeonardoKey
        }
        if id.contains("vast") || id.contains("comfy") {
            return hasVastKey
        }
        return hasFalKey || hasGoogleKey || hasLeonardoKey || hasVastKey || hasAnyDirectKey
    }
}
