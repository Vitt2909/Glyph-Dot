import XCTest
@testable import GlyphCore

final class ProtocolTests: XCTestCase {
    let codec = LineCodec()
    let t0 = ISO8601.parse("2026-09-29T21:10:00Z")!

    func testSpecExampleDecodes() throws {
        // Exemplo literal de docs/PROTOCOL.md.
        let line = #"{"v":0,"id":"a1","type":"approval.request","ts":"2026-09-29T21:10:00Z","action":"git.push","target":"origin/glyph/fix-tests","class":"external_effect","why":"Testes voltaram a passar; abrir PR de rascunho?","timeoutSec":120}"#
        let env = try codec.decode(line)
        XCTAssertEqual(env.v, 0)
        XCTAssertEqual(env.id, "a1")
        XCTAssertEqual(env.type, "approval.request")
        XCTAssertEqual(env.ts, t0)
        guard case let .approvalRequest(r) = env.message else { return XCTFail("tipo errado") }
        XCTAssertEqual(r.action, "git.push")
        XCTAssertEqual(r.actionClass, .externalEffect)
        XCTAssertEqual(r.timeoutSec, 120)
    }

    func testRoundTripEveryMessageKind() throws {
        let messages: [Message] = [
            .hello(Hello(role: .body, capabilities: ["overlay"], name: "Glyph.app")),
            .worldUpdate(WorldUpdate(activeApp: "Terminal", activePID: 42, idleSeconds: 3.5, cursorNearGlyph: true, focus: .typing)),
            .inputSummon(InputSummon(source: .hotkey, text: "quanto está o dólar?")),
            .inputBrake(InputBrake(engage: true)),
            .approvalResponse(ApprovalResponse(requestId: "a1", decision: .approve)),
            .approvalResponse(ApprovalResponse(requestId: "a2", decision: .deny)),
            .approvalResponse(ApprovalResponse(requestId: "a3", decision: .always(scope: "compute:~/dev/vk", expires: t0))),
            .bodyGoto(BodyGoto(target: .window(pid: 7, frame: Rect(x: 10, y: 20, width: 300, height: 200)))),
            .bodyGoto(BodyGoto(target: .point(Vec2(1, 2)))),
            .bodyGoto(BodyGoto(target: .home)),
            .bodyEmote(BodyEmote(clip: "wave", dot: .pulse)),
            .bodyEmote(BodyEmote(clip: "idle")),
            .bubbleSay(BubbleSay(text: "hm.")),
            .approvalRequest(ApprovalRequest(action: "git.push", target: "origin/x", actionClass: .externalEffect, why: "ok?")),
            .taskUpdate(TaskUpdate(taskId: "t", step: "s", progress: 0.5, budgetRemaining: 3)),
            .agentSpawn(AgentSpawn(agentId: "b1", role: .builder)),
            .agentDespawn(AgentDespawn(agentId: "b1")),
            .diaryReady(DiaryReady(path: "/tmp/diario/2026-09-29.md")),
        ]
        XCTAssertEqual(Set(messages.map(\.kind)), Set(Message.Kind.allCases), "todo tipo precisa de teste")
        for (i, m) in messages.enumerated() {
            let env = Envelope(id: "id\(i)", ts: t0, message: m)
            let data = try codec.encode(env)
            XCTAssertEqual(data.last, 0x0A)
            XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1, "uma mensagem, uma linha")
            XCTAssertEqual(try codec.decode(data), env)
        }
    }

    func testEnvelopeIsFlatJSON() throws {
        let env = Envelope(id: "x", ts: t0, message: .bubbleSay(BubbleSay(text: "oi")))
        let obj = try JSONSerialization.jsonObject(with: try codec.encode(env)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "bubble.say")
        XCTAssertEqual(obj["text"] as? String, "oi")
        XCTAssertEqual(obj["ts"] as? String, "2026-09-29T21:10:00Z")
        XCTAssertEqual(obj["v"] as? Int, 0)
    }

    func testUnknownTypeIsRejected() {
        XCTAssertThrowsError(try codec.decode(#"{"v":0,"id":"1","type":"body.teleport","ts":"2026-09-29T21:10:00Z"}"#)) { e in
            XCTAssertEqual(e as? ProtocolError, .unknownType("body.teleport"))
        }
    }

    func testFractionalSecondsAccepted() throws {
        let env = try codec.decode(#"{"v":0,"id":"1","type":"agent.despawn","ts":"2026-09-29T21:10:00.250Z","agentId":"a"}"#)
        XCTAssertEqual(env.ts.timeIntervalSince(t0), 0.25, accuracy: 0.001)
    }

    func testApprovalRequestOnlyFromBrain() throws {
        let env = Envelope(id: "a", ts: t0, message: .approvalRequest(
            ApprovalRequest(action: "x", target: "y", actionClass: .compute, why: "z")))
        XCTAssertNoThrow(try ProtocolValidator.validate(env, from: .brain))
        XCTAssertThrowsError(try ProtocolValidator.validate(env, from: .body)) { e in
            XCTAssertEqual(e as? ProtocolError, .notAllowed(type: "approval.request", sender: .body))
        }
    }

    func testApprovalResponseOnlyFromBody() throws {
        let env = Envelope(id: "a", ts: t0, message: .approvalResponse(ApprovalResponse(requestId: "r", decision: .approve)))
        XCTAssertNoThrow(try ProtocolValidator.validate(env, from: .body))
        XCTAssertThrowsError(try ProtocolValidator.validate(env, from: .brain))
    }

    func testSenderMatrix() {
        for kind in Message.Kind.allCases {
            XCTAssertFalse(kind.allowedSenders.isEmpty, "\(kind) sem remetente")
        }
        XCTAssertEqual(Message.Kind.bodyGoto.allowedSenders, [.brain], "o corpo nunca manda o corpo andar")
        XCTAssertEqual(Message.Kind.worldUpdate.allowedSenders, [.body], "só o corpo percebe o mundo")
    }

    func testValidatorRejectsBadPayloads() {
        func check(_ m: Message, _ from: Peer) -> Bool {
            (try? ProtocolValidator.validate(Envelope(id: "1", ts: t0, message: m), from: from)) != nil
        }
        XCTAssertFalse(check(.approvalRequest(ApprovalRequest(action: "pay", target: "x", actionClass: .financial, why: "")), .brain),
                       "financial é proibida")
        XCTAssertFalse(check(.approvalRequest(ApprovalRequest(action: "a", target: "b", actionClass: .compute, why: "", timeoutSec: 0)), .brain))
        XCTAssertFalse(check(.taskUpdate(TaskUpdate(taskId: "t", step: "s", progress: 1.5)), .brain))
        XCTAssertFalse(check(.taskUpdate(TaskUpdate(taskId: "t", step: "s", progress: 0.5, budgetRemaining: -1)), .brain))
        XCTAssertFalse(check(.hello(Hello(role: .brain)), .body), "hello precisa declarar o papel real")
        XCTAssertFalse(check(.bubbleSay(BubbleSay(text: "x", durationSec: 0)), .brain))
        XCTAssertTrue(check(.hello(Hello(role: .body)), .body))
    }

    func testUnsupportedVersion() {
        let env = Envelope(v: 99, id: "1", ts: t0, message: .hello(Hello(role: .brain)))
        XCTAssertThrowsError(try ProtocolValidator.validate(env, from: .brain)) { e in
            XCTAssertEqual(e as? ProtocolError, .unsupportedVersion(99))
        }
    }

    func testNegotiation() {
        XCTAssertEqual(ProtocolValidator.negotiate(Hello(role: .body, protocolVersions: [0, 1]),
                                                   Hello(role: .brain, protocolVersions: [0])), 0)
        XCTAssertNil(ProtocolValidator.negotiate(Hello(role: .body, protocolVersions: [1]),
                                                 Hello(role: .brain, protocolVersions: [0])))
    }

    func testBubbleDisplayTextIsCapped() {
        XCTAssertEqual(BubbleSay(text: "curto").displayText, "curto")
        let long = BubbleSay(text: String(repeating: "a", count: 100)).displayText
        XCTAssertEqual(long.count, BubbleSay.maxLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testIrreversibleClasses() {
        XCTAssertEqual(ActionClass.externalEffect.isReversible, false)
        XCTAssertEqual(ActionClass.destructive.isReversible, false)
        XCTAssertEqual(ActionClass.financial.isReversible, false)
        XCTAssertEqual(ActionClass.compute.isReversible, true)
        XCTAssertEqual(ActionClass.localWrite.isReversible, true)
        XCTAssertEqual(ActionClass(rawValue: "local_write"), .localWrite)
    }
}

final class LineBufferTests: XCTestCase {
    func testSplitsAcrossChunks() {
        var b = LineBuffer()
        XCTAssertTrue(b.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = b.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8))
        XCTAssertEqual(lines.compactMap { try? $0.get() }.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
        let rest = b.append(Data(":3}\n".utf8))
        XCTAssertEqual(rest.count, 1)
    }

    func testSkipsEmptyLines() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("\n\n{}\n".utf8)).count, 1)
    }

    func testRejectsHugeLine() {
        var b = LineBuffer(maxLineBytes: 8)
        let out = b.append(Data(String(repeating: "x", count: 20).utf8))
        XCTAssertEqual(out.count, 1)
        guard case .failure(.lineTooLong) = out[0] else { return XCTFail() }
        // Depois de descartar, o buffer volta a funcionar.
        XCTAssertEqual(b.append(Data("\n{}\n".utf8)).count, 1)
    }
}

final class MockBrainTests: XCTestCase {
    func testScriptIsValidProtocol() throws {
        var brain = MockBrain(loops: false)
        let envs = brain.poll(elapsed: 1_000)
        XCTAssertEqual(envs.count, MockBrain.defaultScript.count)
        for env in envs { XCTAssertNoThrow(try ProtocolValidator.validate(env, from: .brain), "\(env.type)") }
        XCTAssertEqual(Set(envs.map(\.id)).count, envs.count, "ids únicos")
    }

    func testPollRespectsTime() {
        var brain = MockBrain(loops: false)
        XCTAssertTrue(brain.poll(elapsed: 0.5).isEmpty)
        XCTAssertEqual(brain.poll(elapsed: 1.0).map(\.type), ["hello"])
        XCTAssertEqual(brain.poll(elapsed: 2.0).map(\.type), ["body.emote"])
        XCTAssertTrue(brain.poll(elapsed: 2.5).isEmpty)
    }

    func testLoops() {
        var brain = MockBrain(script: [.init(at: 0, .bodyGoto(BodyGoto(target: .home)))], loops: true)
        XCTAssertEqual(brain.poll(elapsed: 0).count, 1)
        XCTAssertEqual(brain.poll(elapsed: 4).count, 0)
        XCTAssertEqual(brain.poll(elapsed: brain.period).count, 1)
    }

    func testRespondsToSummonAndApproval() throws {
        var brain = MockBrain()
        let summon = Envelope(id: "s", message: .inputSummon(InputSummon(source: .click)))
        let replies = brain.respond(to: summon)
        XCTAssertTrue(replies.contains { $0.type == "bubble.say" })
        for r in replies { XCTAssertNoThrow(try ProtocolValidator.validate(r, from: .brain)) }
        let deny = Envelope(id: "d", message: .approvalResponse(ApprovalResponse(requestId: "a", decision: .deny)))
        XCTAssertEqual(brain.respond(to: deny).count, 1)
    }
}
