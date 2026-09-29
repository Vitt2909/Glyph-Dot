#if canImport(AppKit)
import AppKit
import GlyphCore

/// M0: abre um overlay por tela e mostra o Glyph parado sobre o Dock.
/// Com `GLYPH_MOCK=1`, um `MockBrain` manda bolhas e emoções falsas.
@MainActor
public final class GlyphAppDelegate: NSObject, NSApplicationDelegate {
    private var overlays: [OverlayController] = []
    private var timer: Timer?
    private var mock: MockBrain?
    private let started = Date()
    private var bubble: (text: String, until: Date)?
    private var dotMode: DotMode = .steady
    private var frame = 0

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["GLYPH_MOCK"] == "1" {
            mock = MockBrain()
        }
        rebuildOverlays()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildOverlays() }
        }
        // 12 fps: a pose é amostrada "em dois" e o traço ferve a cada 3 quadros.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / StickerStyle.default.poseFPS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        overlays.forEach { $0.close() }
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { screen in
            let o = OverlayController(screen: screen)
            o.view.onMouseDown = { [weak self] event in self?.mouseDown(event) }
            return o
        }
    }

    /// Chão do M0: topo do Dock na tela principal (ou a borda da tela se o Dock estiver oculto).
    private var standingPoint: Vec2 {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return Vec2(200, 100) }
        let floor = screen.visibleFrame.minY
        return Vec2(screen.frame.midX, floor)
    }

    private func tick() {
        frame += 1
        if var brain = mock {
            for env in brain.poll(elapsed: Date().timeIntervalSince(started)) { handle(env) }
            mock = brain
        }
        if let b = bubble, b.until < Date() { bubble = nil }

        var drawing = GlyphDrawing.standing(at: standingPoint)
        drawing.boilFrame = frame
        drawing.bubble = bubble?.text
        drawing.dot.alert = dotMode == .alert
        drawing.dot.sleeping = dotMode == .fade
        if dotMode == .fade { drawing.dot.opacity = 0.4 }
        for o in overlays { o.show(drawing) }
    }

    private func handle(_ env: Envelope) {
        guard (try? ProtocolValidator.validate(env, from: .brain)) != nil else { return }
        switch env.message {
        case let .bubbleSay(b):
            bubble = (b.displayText, Date().addingTimeInterval(b.durationSec))
        case let .bodyEmote(e):
            dotMode = e.dot ?? .steady
        case let .approvalRequest(r):
            bubble = (BubbleSay(text: r.why).displayText, Date().addingTimeInterval(4))
        default:
            break
        }
    }

    private func mouseDown(_ event: NSEvent) {
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            let menu = NSMenu()
            menu.addItem(withTitle: "Sair do Glyph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            NSMenu.popUpContextMenu(menu, with: event, for: overlays.first?.view ?? NSView())
            return
        }
        bubble = (mock == nil ? "oi." : "(mock) oi.", Date().addingTimeInterval(BubbleSay.defaultDuration))
        if var brain = mock {
            for env in brain.respond(to: Envelope(id: "click", message: .inputSummon(InputSummon(source: .click)))) {
                handle(env)
            }
            mock = brain
        }
    }
}
#endif
