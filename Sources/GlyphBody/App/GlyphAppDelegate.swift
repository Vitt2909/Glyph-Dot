#if canImport(AppKit)
import AppKit
import GlyphCore

/// O app: um `BodyController` e, com `GLYPH_MOCK=1`, um cérebro falso.
///
/// Sem `glyphd` (M2) e sem mock, o Glyph é a criatura "muda" do M1: vive,
/// anda, reage ao cursor, mas não fala com cérebro nenhum.
@MainActor
public final class GlyphAppDelegate: NSObject, NSApplicationDelegate {
    private var body: BodyController?
    private var mock: MockBrain?
    private var mockTimer: Timer?
    private let started = Date()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let (clips, errors) = ClipLibrary.load(pack: PackLocator.find())
        for e in errors { FileHandle.standardError.write(Data("pack: \(e)\n".utf8)) }
        if clips.clips.isEmpty {
            FileHandle.standardError.write(Data("pack: nenhum clipe encontrado; o Glyph vai ficar parado\n".utf8))
        }

        let body = BodyController(clips: clips)
        self.body = body

        if ProcessInfo.processInfo.environment["GLYPH_MOCK"] == "1" {
            mock = MockBrain()
            body.onSend = { [weak self] m in self?.sendToMock(m) }
            mockTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollMock() }
            }
        }
        body.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        mockTimer?.invalidate()
        body?.stop()
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
