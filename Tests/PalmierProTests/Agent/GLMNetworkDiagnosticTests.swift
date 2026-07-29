import Foundation
import Testing
@testable import PalmierPro

@Suite("GLMNetworkDiagnostic", .serialized)
struct GLMNetworkDiagnosticTests {

    private var apiKey: String {
        GLMKeychain.load() ?? "454921beaf4640bdb6d60915a0d6fd83.lnXjBWF29911rDT9"
    }

    // MARK: - Diagnostic Test 1: Simple Prompt

    @Test func testSimplePromptConnection() async throws {
        let key = apiKey
        guard !key.isEmpty else {
            Issue.record("No GLM API key available for diagnostic test")
            return
        }

        print("\n=== DIAGNOSTIC 1: Simple Prompt ('hello') ===")
        let client = GLMClient(apiKey: key, modelName: "glm-5.2")
        var eventsCount = 0
        var receivedText = ""

        do {
            let stream = client.stream(
                system: "You are a helpful assistant.",
                tools: [],
                messages: [AnthropicMessage(role: .user, content: [["type": "text", "text": "hello"]])]
            )
            for try await event in stream {
                eventsCount += 1
                if case .textDelta(let chunk) = event {
                    receivedText += chunk
                }
            }
            print("[DIAGNOSTIC 1 SUCCESS] Events: \(eventsCount), Response: \(receivedText.prefix(60))...")
            #expect(eventsCount > 0)
        } catch {
            print("[DIAGNOSTIC 1 FAIL] Error: \(error.localizedDescription) (\(error))")
            throw error
        }
    }

    // MARK: - Diagnostic Test 2: Full System Prompt

    @Test func testFullSystemPromptConnection() async throws {
        let key = apiKey
        guard !key.isEmpty else { return }

        print("\n=== DIAGNOSTIC 2: Full System Prompt (without tools) ===")
        let client = GLMClient(apiKey: key, modelName: "glm-5.2")
        let fullSystem = AgentInstructions.serverInstructions
        print("System prompt length: \(fullSystem.count) chars")

        var eventsCount = 0
        do {
            let stream = client.stream(
                system: fullSystem,
                tools: [],
                messages: [AnthropicMessage(role: .user, content: [["type": "text", "text": "hi"]])]
            )
            for try await event in stream {
                eventsCount += 1
            }
            print("[DIAGNOSTIC 2 SUCCESS] Events: \(eventsCount)")
            #expect(eventsCount > 0)
        } catch {
            print("[DIAGNOSTIC 2 FAIL] Error: \(error.localizedDescription) (\(error))")
            throw error
        }
    }

    // MARK: - Diagnostic Test 3: Full In-App Tools

    @Test func testFullInAppToolsConnection() async throws {
        let key = apiKey
        guard !key.isEmpty else { return }

        print("\n=== DIAGNOSTIC 3: Full In-App Tools (without system prompt) ===")
        let client = GLMClient(apiKey: key, modelName: "glm-5.2")
        let tools = ToolDefinitions.inAppAgent.map {
            AnthropicToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }
        print("Tools count: \(tools.count)")

        var eventsCount = 0
        do {
            let stream = client.stream(
                system: "You are a video editing assistant.",
                tools: tools,
                messages: [AnthropicMessage(role: .user, content: [["type": "text", "text": "hello"]])]
            )
            for try await event in stream {
                eventsCount += 1
            }
            print("[DIAGNOSTIC 3 SUCCESS] Events: \(eventsCount)")
            #expect(eventsCount > 0)
        } catch {
            print("[DIAGNOSTIC 3 FAIL] Error: \(error.localizedDescription) (\(error))")
            throw error
        }
    }

    // MARK: - Diagnostic Test 4: Complete Agent Payload (System + Tools)

    @Test func testCompleteAgentPayloadConnection() async throws {
        let key = apiKey
        guard !key.isEmpty else { return }

        print("\n=== DIAGNOSTIC 4: Complete Agent Payload (Full System + Full Tools) ===")
        let client = GLMClient(apiKey: key, modelName: "glm-5.2")
        let fullSystem = await AgentInstructions.serverInstructions + AgentInstructions.skillsSection(SkillStore.shared.skillIndex)
        let tools = ToolDefinitions.inAppAgent.map {
            AnthropicToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }

        print("Full System len: \(fullSystem.count), Tools count: \(tools.count)")
        var eventsCount = 0
        do {
            let stream = client.stream(
                system: fullSystem,
                tools: tools,
                messages: [AnthropicMessage(role: .user, content: [["type": "text", "text": "hello"]])]
            )
            for try await event in stream {
                eventsCount += 1
            }
            print("[DIAGNOSTIC 4 SUCCESS] Events: \(eventsCount)")
            #expect(eventsCount > 0)
        } catch {
            print("[DIAGNOSTIC 4 FAIL] Error: \(error.localizedDescription) (\(error))")
            throw error
        }
    }
}
