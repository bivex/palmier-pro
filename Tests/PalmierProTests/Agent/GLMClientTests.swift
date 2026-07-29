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
        url: URL(string: "https://api.z.ai/api/anthropic/v1/messages")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
    )!
}

private func sseLines(_ lines: [String]) -> Data {
    Data((lines + [""]).joined(separator: "\n").utf8)
}

private func textChunkLine(_ text: String) -> String {
    let json = String(data: try! JSONSerialization.data(withJSONObject: [
        "type": "content_block_delta",
        "index": 0,
        "delta": ["type": "text_delta", "text": text]
    ]), encoding: .utf8)!
    return "event: content_block_delta\ndata: \(json)"
}

private func messageStopLine() -> String {
    let json = String(data: try! JSONSerialization.data(withJSONObject: [
        "type": "message_delta",
        "delta": ["stop_reason": "end_turn"]
    ]), encoding: .utf8)!
    return "event: message_delta\ndata: \(json)"
}

private func toolUseLines(id: String, name: String) -> [String] {
    let startJson = String(data: try! JSONSerialization.data(withJSONObject: [
        "type": "content_block_start",
        "index": 0,
        "content_block": ["type": "tool_use", "id": id, "name": name]
    ]), encoding: .utf8)!
    let stopJson = String(data: try! JSONSerialization.data(withJSONObject: [
        "type": "content_block_stop",
        "index": 0
    ]), encoding: .utf8)!
    let msgStopJson = String(data: try! JSONSerialization.data(withJSONObject: [
        "type": "message_delta",
        "delta": ["stop_reason": "tool_use"]
    ]), encoding: .utf8)!
    return [
        "event: content_block_start", "data: \(startJson)",
        "event: content_block_stop", "data: \(stopJson)",
        "event: message_delta", "data: \(msgStopJson)"
    ]
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

// MARK: - Tests (serialised — Swift Testing runs them sequentially)

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
        let errBody = #"{"error":{"code":"1113","message":"Insufficient balance."}}"#
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
                messageStopLine()
            ])
            return (makeHTTPResponse(status: 200), data)
        }
        let events = try await collectEvents(apiKey: "k")
        let texts = events.compactMap { if case .textDelta(let t) = $0, !t.isEmpty { return t } else { return nil } }
        #expect(texts == ["Hello", ", world"])
        #expect(events.contains { if case .messageStop(.endTurn) = $0 { return true }; return false })
    }

    @Test func parsesToolCallAndEmitsToolUseComplete() async throws {
        _ClosureProtocol.currentHandler = { _ in
            let data = sseLines(toolUseLines(id: "call_abc", name: "get_timeline"))
            return (makeHTTPResponse(status: 200), data)
        }
        let events = try await collectEvents(apiKey: "k")
        guard let toolEvent = events.first(where: { if case .toolUseComplete = $0 { return true }; return false }),
              case .toolUseComplete(let id, let name, _) = toolEvent else {
            Issue.record("expected toolUseComplete"); return
        }
        #expect(id == "call_abc")
        #expect(name == "get_timeline")
        #expect(events.contains { if case .messageStop(.toolUse) = $0 { return true }; return false })
    }

    // MARK: Request correctness

    @Test func requestTargetsZAIEndpoint() async {
        let capturedRequest = SendableBox<URLRequest?>(nil)
        _ClosureProtocol.currentHandler = { req in
            capturedRequest.value = req
            return (makeHTTPResponse(status: 200), sseLines([messageStopLine()]))
        }
        _ = try? await collectEvents(apiKey: "k")
        #expect(capturedRequest.value?.url?.host == "api.z.ai")
        #expect(capturedRequest.value?.url?.path == "/api/anthropic/v1/messages")
    }

    @Test func requestCarriesAPIKeyHeaders() async {
        let capturedRequest = SendableBox<URLRequest?>(nil)
        _ClosureProtocol.currentHandler = { req in
            capturedRequest.value = req
            return (makeHTTPResponse(status: 200), sseLines([messageStopLine()]))
        }
        _ = try? await collectEvents(apiKey: "my-secret")
        #expect(capturedRequest.value?.value(forHTTPHeaderField: "x-api-key") == "my-secret")
        #expect(capturedRequest.value?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func requestBodyContainsSelectedModelName() async throws {
        let capturedBody = SendableBox<[String: Any]?>(nil)
        _ClosureProtocol.currentHandler = { req in
            capturedBody.value = extractBodyData(from: req)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (makeHTTPResponse(status: 200), sseLines([messageStopLine()]))
        }
        _ = try? await collectEvents(apiKey: "k", modelName: "glm-4.5")
        let modelName = capturedBody.value?["model"] as? String
        #expect(modelName == "glm-4.5")
    }
}
