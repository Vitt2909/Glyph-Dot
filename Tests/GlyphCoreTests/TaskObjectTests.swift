import XCTest
@testable import GlyphCore

/// Objetos de tarefa (ideia 3) e ofertas ao redor do objeto (ideia 1).
final class TaskObjectTests: XCTestCase {
    static let stickers: [String: Sticker] = Sticker.load(pack: Packs.defaultPack).0

    func engine() -> GlyphEngine {
        var e = GlyphEngine(world: WorldSnapshot(screens: [TestWorlds.screen]), clips: Packs.library,
                            stickers: Self.stickers, start: Vec2(700, 200))
        run(&e, 1)
        return e
    }

    func run(_ e: inout GlyphEngine, _ seconds: Double) {
        for _ in 0..<Int(seconds * 60) {
            e.advance(by: 1.0 / 60)
            _ = e.drawing
        }
    }

    func click(_ e: inout GlyphEngine, at p: Vec2? = nil) {
        let q = p ?? e.body.position + Vec2(0, 20)
        e.mouseDown(at: q)
        e.mouseUp(at: q)
    }

    func testNewStickersExist() {
        for id in ["envelope", "livro", "pasta"] { XCTAssertNotNil(Self.stickers[id], id) }
    }

    func testCarriesTheTaskObjectAndClickShowsProgress() {
        var e = engine()
        e.receive(.taskUpdate(TaskUpdate(taskId: "t1", step: "tentativa 2", progress: 0.4, object: "chave",
                                         title: "testes verdes", state: .doing)))
        run(&e, 0.1)
        XCTAssertEqual(e.drawing?.held, Self.stickers["chave"], "segura o objeto da tarefa")
        click(&e)
        XCTAssertEqual(e.drawing?.bubble, "testes verdes: tentativa 2 (40%)")
        XCTAssertFalse(e.drainEvents().contains { if case .send(.inputSummon) = $0 { return true }; return false },
                       "clicar no objeto mostra a tarefa, não chama o cérebro")
    }

    func testDoneTaskIsDroppedAfterYouSeeIt() {
        var e = engine()
        e.receive(.taskUpdate(TaskUpdate(taskId: "t1", step: "ok", progress: 1, object: "pasta", title: "organizar Downloads",
                                         state: .done, result: "movi 3.")))
        XCTAssertEqual(e.drawing?.bubble, "organizar Downloads: pronto. movi 3.")
        run(&e, 7)
        XCTAssertNotNil(e.carriedTask, "continua na mão até você ver")
        click(&e)
        XCTAssertNil(e.carriedTask)
    }

    func testNeedsYouShowsWhatIsPending() {
        var e = engine()
        e.receive(.taskUpdate(TaskUpdate(taskId: "p", step: "ensaio", progress: 0.5, object: "pasta", title: "organizar Downloads",
                                         state: .needsYou, pending: "3 casos precisam de decisão.")))
        XCTAssertEqual(e.carriedTask?.line, "organizar Downloads: precisa de você — 3 casos precisam de decisão.")
    }

    func testParkedGoesToTheShelf() {
        var e = engine()
        e.receive(.taskUpdate(TaskUpdate(taskId: "t1", step: "x", progress: 0, object: "chave", title: "a", state: .doing)))
        e.receive(.taskUpdate(TaskUpdate(taskId: "t1", step: "x", progress: 0, object: "chave", title: "a", state: .parked)))
        XCTAssertNil(e.carriedTask)
        XCTAssertNil(e.drawing?.held)
    }

    /// Objeto só com tarefa de verdade, e nunca um sinal de segurança.
    func testNoObjectWithoutTaskAndNoSafetyStickers() {
        var e = engine()
        e.receive(.taskUpdate(TaskUpdate(taskId: "t1", step: "x", progress: 0.2)))
        XCTAssertNil(e.carriedTask, "progresso sem objeto não inventa objeto")
        e.receive(.taskUpdate(TaskUpdate(taskId: "t2", step: "x", progress: 0, object: "cartao")))
        XCTAssertNil(e.carriedTask, "cartão é o sinal de aprovação")
        e.receive(.taskUpdate(TaskUpdate(taskId: "t3", step: "x", progress: 0, object: "nao-existe")))
        XCTAssertNil(e.carriedTask)
    }

    func testMostRecentTaskIsInTheHand() {
        var e = engine()
        e.receive(.taskUpdate(TaskUpdate(taskId: "a", step: "x", progress: 0, object: "chave", title: "a")))
        e.receive(.taskUpdate(TaskUpdate(taskId: "b", step: "x", progress: 0, object: "livro", title: "b")))
        XCTAssertEqual(e.carriedTask?.id, "b")
        e.receive(.taskUpdate(TaskUpdate(taskId: "a", step: "y", progress: 0.5, object: "chave", title: "a")))
        XCTAssertEqual(e.carriedTask?.id, "a")
        XCTAssertEqual(e.tasks.count, 2)
    }

    // MARK: - Ofertas (ideia 1)

    func offer() -> OfferActions {
        OfferActions(offerId: "o1", object: "folha", title: "contrato.pdf",
                     actions: [OfferAction(id: "resumir", label: "resumir", sticker: "folha"),
                               OfferAction(id: "comparar", label: "comparar", sticker: "lupa"),
                               OfferAction(id: "tarefas", label: "extrair tarefas", sticker: "alfinete")])
    }

    func testOfferShowsActionsAroundTheObjectAndClickChooses() {
        var e = engine()
        e.receive(.offerActions(offer()))
        run(&e, 0.1)
        let d = e.drawing!
        XCTAssertEqual(d.props.count, 3)
        XCTAssertEqual(d.held, Self.stickers["folha"])
        XCTAssertEqual(d.bubble, "resumir · comparar · extrair tarefas", "sem espaço para o título")
        let second = e.offerProps[1].prop.center
        XCTAssertTrue(d.bounds.contains(second), "as ações entram na área clicável")
        _ = e.drainEvents()
        click(&e, at: second)
        XCTAssertEqual(e.drainEvents(), [.send(.offerChoice(OfferChoice(offerId: "o1", actionId: "comparar")))])
        XCTAssertNil(e.offer)
    }

    func testShortOfferKeepsTheTitle() {
        var e = engine()
        e.receive(.offerActions(OfferActions(offerId: "o", object: "pasta", title: "fotos",
                                             actions: [OfferAction(id: "mapear", label: "mapear")])))
        XCTAssertEqual(e.drawing?.bubble, "fotos: mapear")
    }

    func testClickOnTheBodyKeepsTheOffer() {
        var e = engine()
        e.receive(.offerActions(offer()))
        run(&e, 0.1)
        click(&e, at: e.body.position + Vec2(0, 10))
        XCTAssertNotNil(e.offer)
        XCTAssertTrue(e.drainEvents().isEmpty)
    }

    func testOfferExpiresAsDismissed() {
        var e = engine()
        var o = offer()
        o.timeoutSec = 1
        e.receive(.offerActions(o))
        _ = e.drainEvents()
        run(&e, 1.2)
        XCTAssertNil(e.offer)
        XCTAssertEqual(e.drainEvents(), [.send(.offerChoice(OfferChoice(offerId: "o1", actionId: nil)))])
    }

    func testDropOnTheGlyphAsksTheBrain() {
        var e = engine()
        XCTAssertFalse(e.dropped(paths: ["/Users/a/x.pdf"], at: Vec2(100, 700)), "longe dele, não pega")
        XCTAssertTrue(e.dropped(paths: ["/Users/a/x.pdf", "relativo"], at: e.body.position + Vec2(0, 20)))
        XCTAssertEqual(e.drainEvents(), [.send(.inputDrop(InputDrop(paths: ["/Users/a/x.pdf"])))])
    }

    // MARK: - Protocolo

    func testNewMessagesRoundTripAndDirection() throws {
        let msgs: [(Message, Peer)] = [
            (.taskShelf(TaskShelf(taskId: "t1", park: true)), .body),
            (.inputDrop(InputDrop(paths: ["/a/b.pdf"])), .body),
            (.offerChoice(OfferChoice(offerId: "o", actionId: "resumir")), .body),
            (.offerActions(offer()), .brain),
            (.taskUpdate(TaskUpdate(taskId: "t", step: "s", progress: 0.1, object: "pasta", title: "x", state: .needsYou, pending: "y")), .brain),
        ]
        for (m, from) in msgs {
            let env = Envelope(id: "x", message: m)
            let back = try LineCodec().decode(try LineCodec().encode(env))
            XCTAssertEqual(back.message, m)
            XCTAssertNoThrow(try ProtocolValidator.validate(back, from: from))
            XCTAssertThrowsError(try ProtocolValidator.validate(back, from: from == .body ? .brain : .body), "\(m.kind)")
        }
    }

    func testValidationRejectsBadPayloads() {
        func bad(_ m: Message, _ from: Peer) {
            XCTAssertThrowsError(try ProtocolValidator.validate(Envelope(id: "x", message: m), from: from), "\(m)")
        }
        bad(.inputDrop(InputDrop(paths: [])), .body)
        bad(.inputDrop(InputDrop(paths: ["relativo.pdf"])), .body)
        bad(.inputDrop(InputDrop(paths: Array(repeating: "/a", count: 21))), .body)
        bad(.taskUpdate(TaskUpdate(taskId: "t", step: "s", progress: 0, object: "../x")), .brain)
        var o = offer()
        o.actions = Array(repeating: OfferAction(id: "a", label: "a"), count: 5)
        bad(.offerActions(o), .brain)
        bad(.offerChoice(OfferChoice(offerId: "", actionId: nil)), .body)
    }
}
