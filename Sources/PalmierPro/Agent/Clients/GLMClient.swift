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

private final class GLMStreamingSession: @unchecked Sendable {
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()
}

/// Agent client for Zhipu AI GLM (GLM-5.2 / GLM-4.5 / GLM-4-Plus) via Z.AI Anthropic proxy endpoint
struct GLMClient: AgentClient {
    let apiKey: String
    let modelName: String
    var maxTokens: Int = 8192
    let session: URLSession

    private static let endpoint = URL(string: "https://api.z.ai/api/anthropic/v1/messages")!

    init(apiKey: String, modelName: String = "glm-5.2", session: URLSession = GLMStreamingSession.defaultSession) {
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
        guard !apiKey.isEmpty else {
            Log.agent.error("GLMClient error: missing API key")
            throw AnthropicClientError.missingAPIKey
        }

        let modelEnum = AnthropicModel(rawValue: modelName) ?? .glm52
        Log.agent.notice("GLMClient connecting endpoint=\(Self.endpoint.absoluteString) model=\(modelEnum.rawValue) messagesCount=\(messages.count)")

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("no-cache", forHTTPHeaderField: "cache-control")
        request.setValue("no", forHTTPHeaderField: "x-accel-buffering")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(
                model: modelEnum, maxTokens: maxTokens, system: system, tools: tools, messages: messages
            ),
            options: [.sortedKeys]
        )

        var attempts = 0
        while true {
            do {
                Log.agent.notice("GLMClient sending HTTP POST request (attempt \(attempts + 1))...")
                let (bytes, response) = try await session.bytes(for: request)
                if let http = response as? HTTPURLResponse {
                    Log.agent.notice("GLMClient received response status=\(http.statusCode)")
                    if http.statusCode >= 400 {
                        var errBody = ""
                        do {
                            for try await line in bytes.lines { errBody += line + "\n" }
                        } catch {}
                        Log.agent.error("GLMClient HTTP error \(http.statusCode): \(errBody.prefix(300))")
                        throw AnthropicClientError.httpError(status: http.statusCode, body: errBody)
                    }
                }

                Log.agent.notice("GLMClient starting SSE line parsing...")
                try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
                Log.agent.notice("GLMClient stream completed successfully")
                break
            } catch let urlErr as URLError where (urlErr.code == .networkConnectionLost || urlErr.code == .notConnectedToInternet || urlErr.code == .timedOut) && attempts < 2 {
                attempts += 1
                Log.agent.warning("GLMClient network error (\(urlErr.localizedDescription)), retrying attempt \(attempts)/2...")
                try Task.checkCancellation()
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            } catch {
                Log.agent.error("GLMClient stream failed with error: \(error.localizedDescription)")
                throw error
            }
        }
    }
}
