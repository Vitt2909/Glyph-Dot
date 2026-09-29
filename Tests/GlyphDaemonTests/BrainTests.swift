import XCTest
@testable import GlyphCore
@testable import GlyphDaemon

final class AnthropicBrainTests: XCTestCase {
    let reply = """
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5",
     "content":[{"type":"thinking","thinking":"","signature":"sig"},
                {"type":"text","text":"Vou pesquisar."},
                {"type":"tool_use","id":"toolu_1","name":"web_search","input":{"query":"dólar hoje"}}],
     "stop_reason":"tool_use","usage":{"input_tokens":120,"output_tokens":30}}
    """

    func testRequestFormat() async throws {
        let t = FakeTransport(json: reply)
        let brain = AnthropicBrain(apiKey: "sk-ant-teste", transport: t)
        let tools = [ToolSpec(name: "web_search", description: "busca", inputSchema: .object(["type": .string("object")]))]
        _ = try await brain.respond(system: "sys", turns: [.user("oi")], tools: tools)
        let req = t.requests[0]
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-teste")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = t.lastBody!
        XCTAssertEqual(body["model"], .string("claude-opus-5-5"))
        XCTAssertEqual(body["max_tokens"], .number(16000))
        XCTAssertEqual(body["fallbacks"], .string("default"))
        XCTAssertEqual(body["output_config"]?["effort"], .string("medium"))
        XCTAssertNil(body["tool_choice"], "forçar ferramenta dá 400 no Opus 5.5")
        XCTAssertNil(body["thinking"], "pensamento não pode ser desligado; omitido")
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["input_schema"]?["type"], .string("object"))
    }

    func testParseToolUseAndReplayRawContent() async throws {
        let t = FakeTransport(json: reply)
        let brain = AnthropicBrain(apiKey: "k", transport: t)
        let r = try await brain.respond(system: "s", turns: [.user("oi")], tools: [])
        XCTAssertEqual(r.stop, .toolUse)
        XCTAssertEqual(r.text, "Vou pesquisar.")
        XCTAssertEqual(r.toolCalls, [ToolCall(id: "toolu_1", name: "web_search", input: .object(["query": .string("dólar hoje")]))])
        XCTAssertEqual(r.usage, Usage(inputTokens: 120, outputTokens: 30))
        // O próximo pedido reenvia o conteúdo exato (bloco de pensamento incluso)
        // e os resultados numa única mensagem de usuário.
        _ = try await brain.respond(system: "s", turns: [.user("oi"), r.assistantTurn,
                                                          .toolResults([ToolResult(callID: "toolu_1", name: "web_search", content: "R$ 5,42")])],
                                    tools: [])
        let msgs = t.lastBody!["messages"]!.arrayValue!
        XCTAssertEqual(msgs[1]["content"]?.arrayValue?.first?["type"], .string("thinking"))
        XCTAssertEqual(msgs[1]["content"]?.arrayValue?.first?["signature"], .string("sig"))
        XCTAssertEqual(msgs[2]["content"]?.arrayValue?.first?["type"], .string("tool_result"))
        XCTAssertEqual(msgs[2]["content"]?.arrayValue?.first?["tool_use_id"], .string("toolu_1"))
    }

    func testRefusalAndFallbackBlocks() throws {
        let j = try JSONValue.parse(Data(#"{"content":[{"type":"fallback","from":{"model":"a"},"to":{"model":"b"}},{"type":"text","text":"ok"}],"stop_reason":"end_turn","model":"b"}"#.utf8))
        let r = try AnthropicBrain.parse(j)
        XCTAssertEqual(r.text, "ok")
        XCTAssertEqual(r.model, "b")
        let refusal = try AnthropicBrain.parse(try JSONValue.parse(Data(#"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#.utf8)))
        XCTAssertEqual(refusal.stop, .refusal("cyber"))
    }

    func testErrorsAndMissingKey() async {
        let t = FakeTransport(status: 400, json: #"{"type":"error","error":{"type":"invalid_request_error","message":"ruim"}}"#)
        do {
            _ = try await AnthropicBrain(apiKey: "k", transport: t).respond(system: "", turns: [.user("x")], tools: [])
            XCTFail()
        } catch {
            XCTAssertEqual(error as? BrainError, .api(status: 400, type: "invalid_request_error", message: "ruim"))
            XCTAssertEqual(t.requests.count, 1, "400 não é repetido")
        }
        do {
            _ = try await AnthropicBrain(apiKey: "", transport: t).respond(system: "", turns: [], tools: [])
            XCTFail()
        } catch {
            XCTAssertEqual(error as? BrainError, .missingKey("anthropic"))
        }
    }

    func testRetriesOverloaded() async throws {
        let n = Counter()
        let t = FakeTransport { _ in
            n.increment()
            return n.value < 2 ? (529, Data(#"{"type":"error","error":{"type":"overloaded_error","message":"x"}}"#.utf8))
                               : (200, Data(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#.utf8))
        }
        let r = try await AnthropicBrain(apiKey: "k", transport: t).respond(system: "", turns: [.user("x")], tools: [])
        XCTAssertEqual(r.text, "ok")
        XCTAssertEqual(n.value, 2)
    }
}

final class OtherBrainTests: XCTestCase {
    func testOpenAIRoundTrip() async throws {
        let t = FakeTransport(json: """
        {"model":"m","choices":[{"message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"c1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"x\\"}"}}]},
          "finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}
        """)
        let b = OpenAIBrain(apiKey: "sk-x", model: "m", transport: t)
        let r = try await b.respond(system: "s", turns: [.user("oi")], tools: [ToolSpec(name: "web_search", description: "", inputSchema: .object([:]))])
        XCTAssertEqual(r.toolCalls.first?.input, .object(["query": .string("x")]))
        XCTAssertEqual(r.stop, .toolUse)
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "authorization"), "Bearer sk-x")
        let msgs = t.lastBody!["messages"]!.arrayValue!
        XCTAssertEqual(msgs[0]["role"], .string("system"))
        XCTAssertEqual(t.lastBody!["tools"]?.arrayValue?.first?["function"]?["name"], .string("web_search"))
        // Resultado de ferramenta vira role=tool com tool_call_id.
        let turns: [ChatTurn] = [.user("oi"), r.assistantTurn, .toolResults([ToolResult(callID: "c1", name: "web_search", content: "r")])]
        let formatted = ChatCompletionsFormat.messages(system: "s", turns: turns, ollama: false)
        XCTAssertEqual(formatted.last?["tool_call_id"], .string("c1"))
        XCTAssertEqual(formatted[2]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"], .string(#"{"query":"x"}"#))
    }

    func testOllamaRoundTrip() async throws {
        let t = FakeTransport(json: #"{"model":"qwen3:8b","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"shell","arguments":{"command":"ls"}}}]},"done_reason":"stop"}"#)
        let r = try await OllamaBrain(transport: t).respond(system: "s", turns: [.user("oi")], tools: [])
        XCTAssertEqual(r.toolCalls.first?.name, "shell")
        XCTAssertEqual(r.toolCalls.first?.input["command"], .string("ls"))
        XCTAssertEqual(t.requests[0].url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(t.lastBody!["stream"], .bool(false))
    }

    func testJSONValueNumbersAndBools() throws {
        let v = try JSONValue.parse(Data(#"{"a":1,"b":true,"c":1.5,"d":null}"#.utf8))
        XCTAssertEqual(v["a"], .number(1))
        XCTAssertEqual(v["b"], .bool(true))
        XCTAssertEqual(v["c"], .number(1.5))
        XCTAssertEqual(v["d"], .null)
        XCTAssertEqual(String(decoding: try JSONValue.number(40).data(), as: UTF8.self), "40")
    }
}
