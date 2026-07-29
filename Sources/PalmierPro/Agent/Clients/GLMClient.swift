import Foundation

extension Notification.Name {
    static let glmAPIKeyChanged = Notification.Name("glmAPIKeyChanged")
}

enum GLMKeychain {
    private static let account = "glm-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .glmAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["GLM_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["ZHIPU_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .glmAPIKeyChanged, object: nil)
    }
}

/// Agent client for Zhipu AI GLM (GLM-5.2 / GLM-4.5 / GLM-4-Plus) via Z.AI Anthropic proxy endpoint
struct GLMClient: AgentClient {
    let apiKey: String
    let modelName: String
    var maxTokens: Int = 8192
    let session: URLSession

    private static let endpoint = URL(string: "https://api.z.ai/api/anthropic/v1/messages")!

    init(apiKey: String, modelName: String = "glm-5.2", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = session
    }

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AnthropicClientError.missingAPIKey }

        let modelEnum = AnthropicModel(rawValue: modelName) ?? .glm52

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(
                model: modelEnum, maxTokens: maxTokens, system: system, tools: tools, messages: messages
            ),
            options: [.sortedKeys]
        )

        var attempts = 0
        while true {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    var errBody = ""
                    do {
                        for try await line in bytes.lines { errBody += line + "\n" }
                    } catch {}
                    throw AnthropicClientError.httpError(status: http.statusCode, body: errBody)
                }

                try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
                break
            } catch let urlErr as URLError where (urlErr.code == .networkConnectionLost || urlErr.code == .notConnectedToInternet || urlErr.code == .timedOut) && attempts < 2 {
                attempts += 1
                try Task.checkCancellation()
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }
        }
    }
}
