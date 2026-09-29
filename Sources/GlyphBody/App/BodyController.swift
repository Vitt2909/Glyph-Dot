#if canImport(AppKit)
import AppKit
import QuartzCore
import GlyphCore

/// Liga o sistema ao `GlyphEngine`: lê o mundo, repassa cursor e mouse,
/// desenha os quadros e ajusta a taxa de quadros ao que o motor pede.
///
/// Nunca executa nada. Mensagens para o cérebro saem por `onSend`.
@MainActor
public final class BodyController: NSObject {
    private var engine: GlyphEngine
    private var overlays: [OverlayController] = []
    private let reader = SystemWorldReader()
    private let cursor = CursorMonitor()
    private let toggler = HitTestToggler()
    private var worldTimer: Timer?
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var lastFPS = -1.0

    /// Mensagens do corpo para o cérebro (`input.summon`, …).
    public var onSend: ((Message) -> Void)?
    /// Duplo clique no Glyph: abrir a casa.
    public var onOpenHome: (() -> Void)?
    /// Estado do mundo para o cérebro (no máximo 1×/s; o link só envia se mudou).
    public var onWorld: ((WorldUpdate) -> Void)?
    private var summaries: [WindowSummary] = []
    private var fullscreen = false
    private var lastWorldReport = Date.distantPast

    public init(clips: ClipLibrary, stickers: [String: Sticker] = [:]) {
        let (snapshot, _) = SystemWorldReader().read()
        engine = GlyphEngine(world: snapshot, clips: clips, stickers: stickers)
        super.init()
    }

    public func start() {
        rebuildOverlays()
        cursor.onMove = { [weak self] p in self?.cursorMoved(p) }
        cursor.start()

        // O mundo é lido a 10 Hz, com diff dentro do motor. Isso também mantém
        // o relógio andando quando o display link está parado (em casa).
        worldTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollWorld() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildOverlays()
                self?.pollWorld()
            }
        }
        pollWorld()
    }

    public func stop() {
        worldTimer?.invalidate()
        displayLink?.invalidate()
        displayLink = nil
        cursor.stop()
        overlays.forEach { $0.close() }
    }

    /// Mensagem do cérebro, já validada.
    public func receive(_ message: Message) {
        engine.receive(message)
        wake()
    }

    /// O que o corpo conta ao cérebro. Sem títulos de janela, sem conteúdo.
    public var worldForBrain: WorldUpdate {
        let front = NSWorkspace.shared.frontmostApplication
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let near = engine.hitbox.map { Vec2(NSEvent.mouseLocation).distance(to: $0.center) < 160 } ?? false
        return WorldUpdate(activeApp: front?.localizedName, activePID: front?.processIdentifier,
                           idleSeconds: max(0, idle), cursorNearGlyph: near,
                           focus: fullscreen ? .fullscreen : .normal,
                           windows: summaries, glyph: engine.isHidden ? nil : engine.body.position)
    }

    /// Ponto acima da cabeça do Glyph (para cartões e o campo de chamada).
    public var headPoint: CGPoint {
        if let b = engine.hitbox { return CGPoint(x: b.midX, y: b.maxY) }
        let s = NSScreen.main?.frame ?? .zero
        return CGPoint(x: s.midX, y: s.maxY - 80)
    }

    public func approvalAnswered() {
        engine.approvalAnswered()
        wake()
    }

    // MARK: - Telas

    private func rebuildOverlays() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { screen in
            let o = OverlayController(screen: screen)
            o.view.onMouseDown = { [weak self] e in self?.mouseDown(e) }
            o.view.onMouseDragged = { [weak self] _ in self?.mouseDragged() }
            o.view.onMouseUp = { [weak self] _ in self?.mouseUp() }
            return o
        }
        displayLink?.invalidate()
        displayLink = nil
        if let view = overlays.first?.view {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastFPS = -1
        }
    }

    // MARK: - Entradas

    private func pollWorld() {
        let (snapshot, fullscreen, summaries) = reader.readAll()
        self.summaries = summaries
        self.fullscreen = fullscreen
        engine.setWorld(snapshot)
        engine.setFullscreen(fullscreen)
        if Date().timeIntervalSince(lastWorldReport) >= 1 {
            lastWorldReport = Date()
            onWorld?(worldForBrain)
        }
        if displayLink?.isPaused ?? true {
            // Sem quadros: o relógio anda pelo timer.
            engine.advance(by: 0.1)
            drain()
        }
        wake()
    }

    private func cursorMoved(_ p: CGPoint) {
        engine.setCursor(Vec2(p))
        if let hitbox = engine.hitbox {
            for o in overlays { toggler.update(panel: o.panel, hitbox: hitbox.cgRect, mouse: p) }
        }
        wake()
    }

    private func mouseDown(_ event: NSEvent) {
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showMenu(event)
            return
        }
        engine.mouseDown(at: Vec2(NSEvent.mouseLocation))
        wake()
    }

    private func mouseDragged() {
        engine.mouseDragged(to: Vec2(NSEvent.mouseLocation))
        wake()
    }

    private func mouseUp() {
        engine.mouseUp(at: Vec2(NSEvent.mouseLocation))
        drain()
        wake()
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Sair do Glyph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if let view = overlays.first(where: { $0.panel === event.window })?.view ?? overlays.first?.view {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    // MARK: - Quadros

    private func drain() {
        for e in engine.drainEvents() {
            switch e {
            case let .send(m): onSend?(m)
            case .openHome: onOpenHome?()
            case let .openFile(path): NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    /// Ajusta o display link ao que o motor pede: 60 em movimento, 12 parado,
    /// menos dormindo, 0 em casa. Em modo de economia, no máximo 12.
    private func wake() {
        guard let link = displayLink else { return }
        var fps = Float(engine.desiredFPS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { fps = min(fps, 12) }
        if fps <= 0 {
            if !link.isPaused {
                link.isPaused = true
                draw()
            }
            return
        }
        if Double(fps) != lastFPS {
            lastFPS = Double(fps)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 6), maximum: fps, preferred: fps)
        }
        if link.isPaused {
            lastFrame = nil
            link.isPaused = false
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrame.map { now - $0 } ?? 1.0 / 60
        lastFrame = now
        engine.advance(by: dt)
        drain()
        draw()
        wake()
    }

    private func draw() {
        let all = engine.drawings
        for o in overlays { o.show(all) }
    }
}
#endif
