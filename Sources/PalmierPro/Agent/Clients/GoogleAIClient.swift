import Foundation

extension Notification.Name {
    static let googleAIAPIKeyChanged = Notification.Name("googleAIAPIKeyChanged")
}

enum GoogleAIKeychain {
    private static let account = "google-ai-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .googleAIAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["GOOGLE_AI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .googleAIAPIKeyChanged, object: nil)
    }
}

/// Agent client for Google AI Studio (Gemini 2.0 Flash / Gemini 1.5 Pro) via OpenAI-compatible endpoint
struct GoogleAIClient: AgentClient {
    let apiKey: String
    let modelName: String
    var maxTokens: Int = 8192

    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/v1/chat/completions")!

    init(apiKey: String, modelName: String = "gemini-2.0-flash") {
        self.apiKey = apiKey
        self.modelName = modelName
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

        var openAIMessages: [[String: Any]] = []
        if !system.isEmpty {
            openAIMessages.append(["role": "system", "content": system])
        }

        for msg in messages {
            let roleStr = msg.role == .user ? "user" : "assistant"
            var combinedText = ""
            for block in msg.content {
                if let text = block["text"] as? String {
                    combinedText += text
                }
            }
            openAIMessages.append(["role": roleStr, "content": combinedText])
        }

        var openAITools: [[String: Any]] = []
        for t in tools {
            openAITools.append([
                "type": "function",
                "function": [
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.inputSchema
                ]
            ])
        }

        var body: [String: Any] = [
            "model": modelName,
            "messages": openAIMessages,
            "stream": true,
            "max_tokens": maxTokens,
            "temperature": 0.2
        ]
        if !openAITools.isEmpty {
            body["tools"] = openAITools
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errBody = ""
            for try await line in bytes.lines { errBody += line + "\n" }
            throw AnthropicClientError.httpError(status: http.statusCode, body: errBody)
        }

        try await parseOpenAISSE(bytes: bytes, continuation: continuation)
    }

    private func parseOpenAISSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var pendingToolCalls: [Int: (id: String, name: String, jsonAcc: String)] = [:]

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data: ") else { continue }
            let payload = String(trimmed.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any]
            else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.textDelta(content))
            }

            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let index = tc["index"] as? Int ?? 0
                    let id = tc["id"] as? String ?? pendingToolCalls[index]?.id ?? "call_\(index)"
                    let funcObj = tc["function"] as? [String: Any] ?? [:]
                    let name = funcObj["name"] as? String ?? pendingToolCalls[index]?.name ?? ""
                    let argsChunk = funcObj["arguments"] as? String ?? ""

                    let existing = pendingToolCalls[index] ?? (id: id, name: name, jsonAcc: "")
                    pendingToolCalls[index] = (
                        id: id.isEmpty ? existing.id : id,
                        name: name.isEmpty ? existing.name : name,
                        jsonAcc: existing.jsonAcc + argsChunk
                    )
                }
            }

            if let finishReason = firstChoice["finish_reason"] as? String {
                if finishReason == "tool_calls" || finishReason == "function_call" {
                    for (_, callData) in pendingToolCalls {
                        continuation.yield(.toolUseComplete(id: callData.id, name: callData.name, inputJSON: callData.jsonAcc))
                    }
                    pendingToolCalls.removeAll()
                    continuation.yield(.messageStop(stopReason: .toolUse))
                } else if finishReason == "stop" {
                    continuation.yield(.messageStop(stopReason: .endTurn))
                }
            }
        }

        // Flush any remaining tool calls
        for (_, callData) in pendingToolCalls {
            continuation.yield(.toolUseComplete(id: callData.id, name: callData.name, inputJSON: callData.jsonAcc))
        }
    }
}
