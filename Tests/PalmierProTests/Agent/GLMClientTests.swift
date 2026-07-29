import Foundation
import Testing
@testable import PalmierPro

private final class SendableBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class _ClosureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var currentHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let h = Self.currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        do {
            let (resp, data) = try h(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}


// MARK: - Test helpers

private func extractBodyData(from request: URLRequest) -> Data? {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data.isEmpty ? nil : data
}

private func makeHTTPResponse(status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
    )!
}

private func sseLines(_ lines: [String]) -> Data {
    Data((lines + [""]).joined(separator: "\n").utf8)
}

private func textChunkLine(_ text: String, finishReason: String? = nil) -> String {
    var choice: [String: Any] = ["delta": ["content": text], "index": 0]
    if let r = finishReason { choice["finish_reason"] = r }
    let json = String(data: try! JSONSerialization.data(withJSONObject: ["choices": [choice]]), encoding: .utf8)!
    return "data: \(json)"
}

private func reasoningLine(_ text: String) -> String {
    let choice: [String: Any] = ["delta": ["reasoning_content": text], "index": 0]
    let json = String(data: try! JSONSerialization.data(withJSONObject: ["choices": [choice]]), encoding: .utf8)!
    return "data: \(json)"
}

private func toolCallLine(index: Int, id: String, name: String, args: String, finishReason: String? = nil) -> String {
    let tc: [String: Any] = ["index": index, "id": id, "function": ["name": name, "arguments": args]]
    var choice: [String: Any] = ["delta": ["tool_calls": [tc]], "index": 0]
    if let r = finishReason { choice["finish_reason"] = r }
    let json = String(data: try! JSONSerialization.data(withJSONObject: ["choices": [choice]]), encoding: .utf8)!
    return "data: \(json)"
}

private func collectEvents(apiKey: String, modelName: String = "glm-5.2") async throws -> [AnthropicStreamEvent] {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [_ClosureProtocol.self]
    let session = URLSession(configuration: config)
    let client = GLMClient(apiKey: apiKey, modelName: modelName, session: session)
    var events: [AnthropicStreamEvent] = []
    for try await event in client.stream(system: "", tools: [], messages: []) {
        events.append(event)
    }
    return events
}

// MARK: - Tests (serialised — no parallelism annotation, so Swift Testing runs them sequentially)

@Suite("GLMClient", .serialized)
struct GLMClientTests {

    // MARK: Missing key

    @Test func missingAPIKeyThrows() async {
        _ClosureProtocol.currentHandler = { _ in (makeHTTPResponse(status: 200), Data()) }
        await #expect(throws: (any Error).self) {
            _ = try await collectEvents(apiKey: "")
        }
    }

    // MARK: Network connection lost

    @Test func networkConnectionLostThrows() async {
        _ClosureProtocol.currentHandler = { _ in throw URLError(.networkConnectionLost) }
        await #expect(throws: (any Error).self) {
            _ = try await collectEvents(apiKey: "key")
        }
    }

    @Test func cannotConnectToHostThrows() async {
        _ClosureProtocol.currentHandler = { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: (any Error).self) {
            _ = try await collectEvents(apiKey: "key")
        }
    }

    @Test func timedOutThrows() async {
        _ClosureProtocol.currentHandler = { _ in throw URLError(.timedOut) }
        await #expect(throws: (any Error).self) {
            _ = try await collectEvents(apiKey: "key")
        }
    }

    @Test func notConnectedToInternetThrows() async {
        _ClosureProtocol.currentHandler = { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: (any Error).self) {
            _ = try await collectEvents(apiKey: "key")
        }
    }

    // MARK: HTTP errors

    @Test func http401ThrowsWithStatus() async throws {
        _ClosureProtocol.currentHandler = { _ in
            (makeHTTPResponse(status: 401), Data(#"{"error":{"message":"Unauthorized"}}"#.utf8))
        }
        var caught: AnthropicClientError?
        do { _ = try await collectEvents(apiKey: "bad") }
        catch let e as AnthropicClientError { caught = e }
        guard case .httpError(let status, _) = caught else {
            Issue.record("expected httpError(401)"); return
        }
        #expect(status == 401)
    }

    @Test func http429ThrowsWithBody() async throws {
        let errBody = #"{"error":{"code":"1113","message":"余额不足或无可用资源包,请充值。"}}"#
        _ClosureProtocol.currentHandler = { _ in
            (makeHTTPResponse(status: 429), Data(errBody.utf8))
        }
        var caught: AnthropicClientError?
        do { _ = try await collectEvents(apiKey: "key") }
        catch let e as AnthropicClientError { caught = e }
        guard case .httpError(let status, let body) = caught else {
            Issue.record("expected httpError(429)"); return
        }
        #expect(status == 429)
        #expect(body.contains("1113"))
    }

    @Test func http500ThrowsWithStatus() async throws {
        _ClosureProtocol.currentHandler = { _ in
            (makeHTTPResponse(status: 500), Data("Internal Server Error".utf8))
        }
        var caught: AnthropicClientError?
        do { _ = try await collectEvents(apiKey: "key") }
        catch let e as AnthropicClientError { caught = e }
        guard case .httpError(let status, _) = caught else {
            Issue.record("expected httpError(500)"); return
        }
        #expect(status == 500)
    }

    // MARK: SSE parsing

    @Test func parsesTextDeltaAndStop() async throws {
        _ClosureProtocol.currentHandler = { _ in
            let data = sseLines([
                textChunkLine("Hello"),
                textChunkLine(", world"),
                textChunkLine("", finishReason: "stop"),
                "data: [DONE]"
            ])
            return (makeHTTPResponse(status: 200), data)
        }
        let events = try await collectEvents(apiKey: "k")
        let texts = events.compactMap { if case .textDelta(let t) = $0, !t.isEmpty { return t } else { return nil } }
        #expect(texts == ["Hello", ", world"])
        #expect(events.contains { if case .messageStop(.endTurn) = $0 { return true }; return false })
    }

    @Test func parsesReasoningContentFirst() async throws {
        _ClosureProtocol.currentHandler = { _ in
            let data = sseLines([reasoningLine("thinking…"), textChunkLine("answer"), "data: [DONE]"])
            return (makeHTTPResponse(status: 200), data)
        }
        let events = try await collectEvents(apiKey: "k")
        let texts = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
        #expect(texts.first == "thinking…")
        #expect(texts.contains("answer"))
    }

    @Test func parsesToolCallAndEmitsToolUseComplete() async throws {
        _ClosureProtocol.currentHandler = { _ in
            let data = sseLines([
                toolCallLine(index: 0, id: "call_abc", name: "get_timeline", args: "{\"x\":1}", finishReason: "tool_calls"),
                "data: [DONE]"
            ])
            return (makeHTTPResponse(status: 200), data)
        }
        let events = try await collectEvents(apiKey: "k")
        guard let toolEvent = events.first(where: { if case .toolUseComplete = $0 { return true }; return false }),
              case .toolUseComplete(let id, let name, let json) = toolEvent else {
            Issue.record("expected toolUseComplete"); return
        }
        #expect(id == "call_abc")
        #expect(name == "get_timeline")
        #expect(json.contains("\"x\""))
        #expect(events.contains { if case .messageStop(.toolUse) = $0 { return true }; return false })
    }

    @Test func ignoresMalformedAndKeepaliveLines() async throws {
        _ClosureProtocol.currentHandler = { _ in
            let data = sseLines([
                ": keep-alive",
                "not-a-data-line",
                textChunkLine("ok", finishReason: "stop"),
                "data: [DONE]"
            ])
            return (makeHTTPResponse(status: 200), data)
        }
        let events = try await collectEvents(apiKey: "k")
        let texts = events.compactMap { if case .textDelta(let t) = $0, !t.isEmpty { return t } else { return nil } }
        #expect(texts == ["ok"])
    }

    @Test func stopsAtDONESentinel() async throws {
        _ClosureProtocol.currentHandler = { _ in
            let data = sseLines([
                textChunkLine("first"),
                "data: [DONE]",
                textChunkLine("ignored")
            ])
            return (makeHTTPResponse(status: 200), data)
        }
        let events = try await collectEvents(apiKey: "k")
        let texts = events.compactMap { if case .textDelta(let t) = $0, !t.isEmpty { return t } else { return nil } }
        #expect(texts == ["first"])
    }

    // MARK: Request correctness

    @Test func requestTargetsZAIEndpoint() async {
        let capturedRequest = SendableBox<URLRequest?>(nil)
        _ClosureProtocol.currentHandler = { req in
            capturedRequest.value = req
            return (makeHTTPResponse(status: 200), sseLines(["data: [DONE]"]))
        }
        _ = try? await collectEvents(apiKey: "k")
        #expect(capturedRequest.value?.url?.host == "api.z.ai")
    }

    @Test func requestCarriesBearerToken() async {
        let capturedRequest = SendableBox<URLRequest?>(nil)
        _ClosureProtocol.currentHandler = { req in
            capturedRequest.value = req
            return (makeHTTPResponse(status: 200), sseLines(["data: [DONE]"]))
        }
        _ = try? await collectEvents(apiKey: "my-secret")
        #expect(capturedRequest.value?.value(forHTTPHeaderField: "Authorization") == "Bearer my-secret")
    }

    @Test func requestBodyContainsSelectedModelName() async throws {
        let capturedBody = SendableBox<[String: Any]?>(nil)
        _ClosureProtocol.currentHandler = { req in
            capturedBody.value = extractBodyData(from: req)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (makeHTTPResponse(status: 200), sseLines(["data: [DONE]"]))
        }
        _ = try? await collectEvents(apiKey: "k", modelName: "glm-4.5")
        let modelName = capturedBody.value?["model"] as? String
        #expect(modelName == "glm-4.5")
    }

    @Test func requestBodyContainsThinkingEnabled() async throws {
        let capturedBody = SendableBox<[String: Any]?>(nil)
        _ClosureProtocol.currentHandler = { req in
            capturedBody.value = extractBodyData(from: req)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (makeHTTPResponse(status: 200), sseLines(["data: [DONE]"]))
        }
        _ = try? await collectEvents(apiKey: "k")
        let thinking = capturedBody.value?["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
    }
}
