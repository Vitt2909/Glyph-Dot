#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
import GlyphCore

/// O app: o corpo, ligado ao `glyphd` pelo socket (ou ao cérebro falso com
/// `GLYPH_MOCK=1`). Sem `glyphd`, o Glyph é a criatura "muda" do M1.
@MainActor
public final class GlyphAppDelegate: NSObject, NSApplicationDelegate {
    private var body: BodyController?
    private var link: BrainLink?
    private var mock: MockBrain?
    private var mockTimer: Timer?
    private let started = Date()
    private lazy var summonPanel = SummonPanel()
    private lazy var approvalCard = ApprovalCard()
    private lazy var homePanel = HomePanelController()
    private var braked = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let pack = PackLocator.find()
        let (clips, errors) = ClipLibrary.load(pack: pack)
        let (stickers, stickerErrors) = Sticker.load(pack: pack)
        for e in errors + stickerErrors { FileHandle.standardError.write(Data("pack: \(e)\n".utf8)) }
        if clips.clips.isEmpty {
            FileHandle.standardError.write(Data("pack: nenhum clipe encontrado; o Glyph vai ficar parado\n".utf8))
        }

        let body = BodyController(clips: clips, stickers: stickers)
        self.body = body

        if ProcessInfo.processInfo.environment["GLYPH_MOCK"] == "1" {
            mock = MockBrain()
            body.onSend = { [weak self] m in self?.sendToMock(m) }
            mockTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollMock() }
            }
        } else {
            let link = BrainLink(socketPath: BrainLink.defaultSocketPath)
            link.onMessage = { [weak self] env in self?.fromBrain(env) }
            body.onSend = { [weak link] m in link?.send(m) }
            body.onWorld = { [weak link] w in link?.updateWorld(w) }
            link.start()
            self.link = link
        }

        body.onOpenHome = { [weak self] in self?.homePanel.show() }
        summonPanel.onSubmit = { [weak self] text in self?.summon(text) }
        approvalCard.onAnswer = { [weak self] id, decision in
            self?.link?.send(.approvalResponse(ApprovalResponse(requestId: id, decision: decision)))
            self?.body?.approvalAnswered()
        }
        // ⌃⌥Espaço: chamar o Glyph.
        HotKeyCenter.shared.register(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            guard let self, let body = self.body else { return }
            self.summonPanel.show(above: body.headPoint)
        }
        // ⌃⌥⌘.: freio global. Pausa tudo; apertar de novo solta.
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_Period, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggleBrake()
        }
        body.start()
    }

    private func toggleBrake() {
        braked.toggle()
        link?.send(.inputBrake(InputBrake(engage: braked)))
        approvalCard.orderOut(nil)
        if braked {
            // Não espera o cérebro: o corpo já vai para casa.
            body?.receive(.bodyGoto(BodyGoto(target: .home)))
        } else {
            body?.receive(.bubbleSay(BubbleSay(text: "voltei.")))
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        mockTimer?.invalidate()
        link?.stop()
        HotKeyCenter.shared.unregisterAll()
        body?.stop()
    }

    private func summon(_ text: String) {
        braked = false
        if mock != nil {
            sendToMock(.inputSummon(InputSummon(source: .hotkey, text: text)))
            return
        }
        guard let link, link.isConnected else {
            body?.receive(.bubbleSay(BubbleSay(text: "sem cérebro: glyphd parado.")))
            return
        }
        link.send(.inputSummon(InputSummon(source: .hotkey, text: text)))
    }

    private func fromBrain(_ env: Envelope) {
        if case let .approvalRequest(r) = env.message, let body {
            approvalCard.show(id: env.id, request: r, above: body.headPoint)
        }
        body?.receive(env.message)
    }

    private func pollMock() {
        guard var brain = mock else { return }
        let envs = brain.poll(elapsed: Date().timeIntervalSince(started))
        mock = brain
        envs.forEach(deliver)
    }

    private func sendToMock(_ m: Message) {
        guard var brain = mock else { return }
        let replies = brain.respond(to: Envelope(id: UUID().uuidString, message: m))
        mock = brain
        replies.forEach(deliver)
    }

    private func deliver(_ env: Envelope) {
        // O corpo valida tudo que chega, inclusive do mock.
        guard (try? ProtocolValidator.validate(env, from: .brain)) != nil else { return }
        body?.receive(env.message)
    }
}

/// Onde está o pack de animações.
enum PackLocator {
    static func find() -> URL {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["GLYPH_PACK"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Pack", isDirectory: true),
           fm.fileExists(atPath: res.appendingPathComponent("clips").path) {
            return res
        }
        // `swift run`: sobe a partir do executável até achar Packs/default.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Packs/default", isDirectory: true)
            if fm.fileExists(atPath: candidate.appendingPathComponent("clips").path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Packs/default", isDirectory: true)
    }
}
#endif
