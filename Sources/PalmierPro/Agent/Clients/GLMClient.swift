import Foundation

extension Notification.Name {
    static let glmAPIKeyChanged = Notification.Name("glmAPIKeyChanged")
}

enum GLMKeychain {
    private static let account = "glm-api-key"

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.save(trimmed, account: account)
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
        return KeychainStore.load(account: account)?.trimmingCharacters(in: .whitespacesAndNewlines)
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

private final class GLMDataStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var buffer = Data()
    private var httpResponse: HTTPURLResponse?
    private var activeSession: URLSession?
    private var dataTask: URLSessionDataTask?

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
        super.init()
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration) {
        let taskSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.activeSession = taskSession
        let task = taskSession.dataTask(with: request)
        self.dataTask = task
        task.resume()
    }

    func cancel() {
        dataTask?.cancel()
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpResponse = http
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if let http = httpResponse, http.statusCode >= 400 {
            return
        }
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: 0..<newlineIndex)
            buffer.removeSubrange(0...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .newlines) {
                continuation.yield(line)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            self.activeSession?.finishTasksAndInvalidate()
            self.activeSession = nil
        }
        if let http = httpResponse, http.statusCode >= 400 {
            let errBody = String(data: buffer, encoding: .utf8) ?? ""
            Log.agent.error("GLMClient HTTP error \(http.statusCode): \(errBody.prefix(300))")
            continuation.finish(throwing: AnthropicClientError.httpError(status: http.statusCode, body: errBody))
            return
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .newlines), !line.isEmpty {
            continuation.yield(line)
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

/// Agent client for Zhipu AI GLM (GLM-5.2 / GLM-4.5 / GLM-4-Plus) via Z.AI Anthropic proxy endpoint
struct GLMClient: AgentClient {
    let apiKey: String
    let modelName: String
    var maxTokens: Int = 8192
    let session: URLSession

    private static let endpoint = URL(string: "https://api.z.ai/api/anthropic/v1/messages")!

    init(apiKey: String, modelName: String = "glm-5.2", session: URLSession = GLMStreamingSession.defaultSession) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
        Log.agent.notice("GLMClient connecting endpoint=\(Self.endpoint.absoluteString) model=\(modelEnum.rawValue) keyPrefix=\(apiKey.prefix(6))... len=\(apiKey.count) messagesCount=\(messages.count)")

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("no-cache", forHTTPHeaderField: "cache-control")
        request.setValue("no", forHTTPHeaderField: "x-accel-buffering")
        let bodyData = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(
                model: modelEnum, maxTokens: maxTokens, system: system, tools: tools, messages: messages
            ),
            options: [.sortedKeys]
        )
        request.httpBody = bodyData
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "content-length")
        Log.agent.notice("GLMClient httpBody size=\(bodyData.count) bytes")

        var attempts = 0
        var activeSession = session
        while true {
            do {
                Log.agent.notice("GLMClient sending HTTP POST request via URLSessionDataTask (attempt \(attempts + 1))...")
                let lineStream = AsyncThrowingStream<String, Error> { streamContinuation in
                    let delegate = GLMDataStreamDelegate(continuation: streamContinuation)
                    delegate.start(request: request, configuration: activeSession.configuration)
                    streamContinuation.onTermination = { _ in
                        delegate.cancel()
                    }
                }

                try await AnthropicSSE.parse(lines: lineStream, continuation: continuation)
                Log.agent.notice("GLMClient stream completed successfully")
                break
            } catch let urlErr as URLError where !Task.isCancelled && (urlErr.code == .networkConnectionLost || urlErr.code == .notConnectedToInternet || urlErr.code == .timedOut) && attempts < 2 {
                attempts += 1
                Log.agent.warning("GLMClient network error (\(urlErr.localizedDescription)), creating fresh session and retrying (attempt \(attempts)/2)...")
                activeSession = URLSession(configuration: session.configuration)
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
