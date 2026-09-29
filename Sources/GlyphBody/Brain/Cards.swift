#if canImport(AppKit)
import AppKit
import GlyphCore

/// Painel flutuante com cara de adesivo: cartão branco, traço preto de 2 pt,
/// cantos arredondados e sombra curta. Base do campo de chamada e do cartão
/// de aprovação.
@MainActor
class StickerCardPanel: NSPanel {
    let card = NSView()

    init(size: NSSize, canBecomeKey: Bool) {
        allowKey = canBecomeKey
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        card.frame = root.bounds.insetBy(dx: 6, dy: 6)
        card.autoresizingMask = [.width, .height]
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 2
        card.layer?.borderColor = NSColor.black.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.25
        card.layer?.shadowRadius = 2
        card.layer?.shadowOffset = CGSize(width: 0, height: -1)
        root.addSubview(card)
        contentView = root
    }

    private let allowKey: Bool
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }

    /// Posiciona acima de um ponto global (a cabeça do Glyph), sem sair da tela.
    func place(above point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var origin = CGPoint(x: point.x - frame.width / 2, y: point.y + 14)
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - frame.width - 8)
        if origin.y + frame.height > vf.maxY { origin.y = point.y - frame.height - 60 }
        setFrameOrigin(origin)
    }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .medium, color: NSColor = .black) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 3
        return l
    }
}

/// Campo para chamar o Glyph com texto (⌃⌥Espaço).
@MainActor
final class SummonPanel: StickerCardPanel, NSTextFieldDelegate {
    private let field = NSTextField()
    var onSubmit: ((String) -> Void)?

    init() {
        super.init(size: NSSize(width: 340, height: 56), canBecomeKey: true)
        field.frame = card.bounds.insetBy(dx: 12, dy: 12)
        field.autoresizingMask = [.width]
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        field.placeholderString = "fala, Glyph…"
        field.delegate = self
        card.addSubview(field)
    }

    func show(above point: CGPoint) {
        field.stringValue = ""
        place(above: point)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            orderOut(nil)
            if !text.isEmpty { onSubmit?(text) }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            orderOut(nil)
            return true
        }
        return false
    }
}

/// O cartão que o Glyph segura quando precisa de aprovação.
@MainActor
final class ApprovalCard: StickerCardPanel {
    private var requestID = ""
    private var timer: Timer?
    var onAnswer: ((String, ApprovalResponse.Decision) -> Void)?

    init() {
        super.init(size: NSSize(width: 320, height: 132), canBecomeKey: false)
    }

    func show(id: String, request r: ApprovalRequest, above point: CGPoint) {
        requestID = id
        card.subviews.forEach { $0.removeFromSuperview() }
        let why = Self.label(r.why, size: 13, weight: .semibold)
        why.frame = NSRect(x: 14, y: 70, width: card.bounds.width - 28, height: 44)
        let what = Self.label("\(r.action) · \(r.target)", size: 11, color: .darkGray)
        what.frame = NSRect(x: 14, y: 50, width: card.bounds.width - 28, height: 18)
        what.lineBreakMode = .byTruncatingMiddle
        card.addSubview(why)
        card.addSubview(what)

        let irreversible = r.actionClass.isReversible == false
        let yes = button("sim", #selector(approve)), no = button("não", #selector(deny))
        yes.frame = NSRect(x: 14, y: 10, width: 70, height: 30)
        no.frame = NSRect(x: 90, y: 10, width: 70, height: 30)
        card.addSubview(yes)
        card.addSubview(no)
        // "Sempre" só para classes reversíveis: irreversível pede sempre.
        if !irreversible {
            let always = button("sempre (14 dias)", #selector(alwaysAllow))
            always.frame = NSRect(x: 166, y: 10, width: 126, height: 30)
            card.addSubview(always)
        }
        place(above: point)
        orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: r.timeoutSec, repeats: false) { [weak self] _ in
            // Sem resposta: o glyphd nega sozinho; o cartão só some.
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return b
    }

    @objc private func approve() { answer(.approve) }
    @objc private func deny() { answer(.deny) }
    @objc private func alwaysAllow() {
        answer(.always(scope: "sessão", expires: Date().addingTimeInterval(14 * 86_400)))
    }

    private func answer(_ d: ApprovalResponse.Decision) {
        timer?.invalidate()
        orderOut(nil)
        onAnswer?(requestID, d)
    }
}
#endif
