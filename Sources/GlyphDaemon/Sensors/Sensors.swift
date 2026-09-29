import Foundation
import GlyphCore
import GlyphIPC

/// Um evento de sensor. Sensores são opt-in e nunca leem a tela.
public struct SensorEvent: Sendable, Equatable, Codable {
    /// `shell.exit`, `git.commit`, `heartbeat`, …
    public var kind: String
    public var cmd: String?
    public var code: Int?
    public var cwd: String?
    public var duration: Double?
    public var repo: String?
    public var head: String?
    public var ts: Date?

    public init(kind: String, cmd: String? = nil, code: Int? = nil, cwd: String? = nil, duration: Double? = nil,
                repo: String? = nil, head: String? = nil, ts: Date? = Date()) {
        self.kind = kind
        self.cmd = cmd
        self.code = code
        self.cwd = cwd
        self.duration = duration
        self.repo = repo
        self.head = head
        self.ts = ts
    }

    public static func decode(_ data: Data) throws -> SensorEvent {
        try JSONDecoder.glyph.decode(SensorEvent.self, from: data)
    }
}

/// Socket dos sensores (`sensors.sock`): o hook do zsh escreve um JSON por
/// linha. Só o mesmo usuário conecta; os eventos são dados, nunca comandos.
public final class SensorServer: @unchecked Sendable {
    private let server: UnixSocketServer
    public var onEvent: (@Sendable (SensorEvent) -> Void)?

    public init(path: String) {
        server = UnixSocketServer(path: path)
    }

    public func start() throws {
        server.onConnection = { [weak self] conn in
            guard conn.peer?.uid == currentUID else { conn.close(); return }
            conn.onRawLine = { [weak self] data in
                // Linhas grandes demais ou inválidas são ignoradas.
                guard data.count < 8192, let e = try? SensorEvent.decode(data) else { return }
                self?.onEvent?(e)
            }
            conn.start()
        }
        try server.start()
    }

    public func stop() { server.stop() }
}

/// Observa repositórios marcados: um commit novo vira `git.commit`.
///
/// Por polling de `git rev-parse HEAD` (funciona em macOS e Linux; FSEvents
/// pode entrar depois sem mudar a interface).
public actor GitWatcher {
    public let repos: [String]
    public let interval: TimeInterval
    private var heads: [String: String] = [:]
    private var task: Task<Void, Never>?
    private let emit: @Sendable (SensorEvent) async -> Void

    public init(repos: [String], interval: TimeInterval = 20, emit: @escaping @Sendable (SensorEvent) async -> Void) {
        self.repos = repos.map { ShellTool.expand($0) }
        self.interval = interval
        self.emit = emit
    }

    public func start() {
        task?.cancel()
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() { task?.cancel() }

    public func poll() async {
        for repo in repos {
            guard let head = Self.head(repo) else { continue }
            if let old = heads[repo], old != head {
                await emit(SensorEvent(kind: "git.commit", cwd: repo, repo: repo, head: head))
            }
            heads[repo] = head
        }
    }

    static func head(_ repo: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repo, "rev-parse", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Raiz do repositório git que contém a pasta, se houver.
    public static func root(of dir: String) -> String? {
        var url = URL(fileURLWithPath: ShellTool.expand(dir))
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}
