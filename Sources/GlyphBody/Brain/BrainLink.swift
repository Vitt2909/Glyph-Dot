#if canImport(AppKit)
import AppKit
import GlyphCore
import GlyphIPC

/// A ligação do corpo com o `glyphd` pelo socket local.
///
/// Reconecta sozinha. Sem `glyphd` rodando, o Glyph continua vivo, só não
/// pensa (a criatura "muda" do M1).
@MainActor
public final class BrainLink {
    public let socketPath: String
    private var connection: LineConnection?
    private var retryTimer: Timer?
    private var counter = 0
    private var lastWorld: WorldUpdate?

    /// Mensagem válida do cérebro (já passou pelo `ProtocolValidator`).
    public var onMessage: ((Envelope) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    public private(set) var isConnected = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public static var defaultSocketPath: String {
        if let custom = ProcessInfo.processInfo.environment["GLYPH_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent("glyphd.sock").path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glyph/glyphd.sock").path
    }

    public func start() {
        connect()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isConnected else { return }
                self.connect()
            }
        }
    }

    public func stop() {
        retryTimer?.invalidate()
        connection?.close()
        connection = nil
    }

    private func connect() {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        guard let conn = try? UnixSocketClient.connect(path: socketPath) else { return }
        conn.onLine = { [weak self] result in
            guard case let .success(env) = result else { return }
            Task { @MainActor in self?.deliver(env) }
        }
        conn.onClose = { [weak self] in
            Task { @MainActor in self?.disconnected() }
        }
        conn.start()
        connection = conn
        isConnected = true
        onConnectionChange?(true)
        send(.hello(Hello(role: .body, capabilities: ["overlay", "approval-card", "summon"], name: "Glyph.app")))
        if let w = lastWorld { send(.worldUpdate(w)) }
    }

    private func disconnected() {
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionChange?(false)
        }
    }

    private func deliver(_ env: Envelope) {
        // O corpo valida tudo: um cérebro não pode mandar o que é do corpo.
        guard (try? ProtocolValidator.validate(env, from: .brain)) != nil else { return }
        onMessage?(env)
    }

    public func send(_ message: Message) {
        guard let connection else { return }
        counter += 1
        connection.send(Envelope(id: "b\(counter)", message: message))
    }

    /// Manda o estado do mundo só quando mudou (sem contar a ociosidade fina).
    public func updateWorld(_ w: WorldUpdate) {
        var comparable = w
        comparable.idleSeconds = (w.idleSeconds / 30).rounded(.down) * 30
        var last = lastWorld
        last?.idleSeconds = ((last?.idleSeconds ?? 0) / 30).rounded(.down) * 30
        lastWorld = w
        if comparable != last { send(.worldUpdate(w)) }
    }
}
#endif
