import Foundation
import GlyphCore

/// Mantém os marcadores dos projetos que você escolheu (`sensores.repos`) em
/// `casa/memoria/projetos/<nome>.md` e percebe quando você volta a um deles.
///
/// Só metadados: ramo, último commit, nomes de arquivos mexidos, código de
/// saída de testes e o arquivo:linha que a autonomia apontou.
public actor ProjectTracker {
    public let repos: [String]
    public let paths: GlyphPaths
    /// Ausência que conta como "voltou".
    public var awayThreshold: TimeInterval = 2 * 3600
    /// Não relê o git mais que isto por projeto.
    public var refreshInterval: TimeInterval = 300
    private var lastSeen: [String: Date] = [:]
    private var lastRefresh: [String: Date] = [:]

    public init(repos: [String], paths: GlyphPaths) {
        self.repos = repos.map { Scope.normalize(ShellTool.expand($0)) }
        self.paths = paths
    }

    public func setAwayThreshold(_ t: TimeInterval) { awayThreshold = t }

    var dir: URL { paths.memoria.appendingPathComponent("projetos", isDirectory: true) }

    public func project(for path: String) -> String? {
        let p = Scope.normalize(ShellTool.expand(path))
        return repos.filter { Scope.contains($0, p) }.max { $0.count < $1.count }
    }

    static func name(_ root: String) -> String { (root as NSString).lastPathComponent }

    func url(_ root: String) -> URL { dir.appendingPathComponent(Self.name(root) + ".md") }

    public func marker(_ root: String) -> ProjectMarker {
        if let text = try? String(contentsOf: url(root), encoding: .utf8), var m = ProjectMarker.parse(text) {
            if m.root.isEmpty { m.root = root }
            return m
        }
        return ProjectMarker(name: Self.name(root), root: root)
    }

    public func save(_ m: ProjectMarker) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? m.render().write(to: url(m.root), atomically: true, encoding: .utf8)
    }

    /// Um evento chegou. Devolve a linha de retomada se você voltou a um
    /// projeto depois de um tempo longe (e há algo a dizer).
    @discardableResult
    public func handle(_ e: SensorEvent, now: Date = Date()) async -> (project: String, line: String)? {
        guard let path = e.cwd ?? e.repo, let root = project(for: path) else { return nil }
        let before = lastSeen[root]
        lastSeen[root] = now
        var m = marker(root)
        // Voltou: diz onde parou, com o que estava guardado antes de atualizar.
        var notice: (String, String)?
        if let before, now.timeIntervalSince(before) >= awayThreshold, let line = m.resumeLine {
            notice = (root, line)
        } else if before == nil, let line = m.resumeLine, let newest = m.facts.map(\.date).max(),
                  now.timeIntervalSince(newest) >= awayThreshold {
            // Primeiro evento desde que o glyphd subiu.
            notice = (root, line)
        }

        var changed = false
        if e.kind == "shell.exit", let cmd = e.cmd, FailureParser.looksLikeTestCommand(cmd), let code = e.code, code != 130 {
            if code == 0 {
                m.set(.failing, nil, origin: "terminal", date: now)
                m.set(.passing, "`\(cmd)`", origin: "terminal", date: now)
            } else if m.fact(.failing)?.origin != "autonomia" {
                // O arquivo:linha que a autonomia apontou é mais útil: fica.
                m.set(.passing, nil, origin: "terminal", date: now)
                m.set(.failing, "`\(cmd)` (código \(code))", origin: "terminal", date: now)
            }
            changed = true
        }
        if e.kind == "git.commit" || now.timeIntervalSince(lastRefresh[root] ?? .distantPast) >= refreshInterval {
            lastRefresh[root] = now
            await refreshGit(&m, now: now)
            changed = true
        }
        if changed { save(m) }
        return notice
    }

    /// A autonomia reexecutou os testes e apontou um arquivo.
    public func testFailure(in scope: String, at evidence: String, now: Date = Date()) {
        guard let root = project(for: scope) else { return }
        var m = marker(root)
        m.set(.passing, nil, origin: "autonomia", date: now)
        m.set(.failing, evidence, origin: "autonomia", date: now)
        save(m)
    }

    public func note(_ project: String, _ text: String, now: Date = Date()) -> ProjectMarker? {
        guard let root = repos.first(where: { Self.name($0) == project }) ?? self.project(for: project) else { return nil }
        var m = marker(root)
        m.addNote(text, date: now)
        save(m)
        return m
    }

    func refreshGit(_ m: inout ProjectMarker, now: Date) async {
        let root = m.root
        if let b = await Self.git(["rev-parse", "--abbrev-ref", "HEAD"], root)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            m.set(.branch, b == "HEAD" ? "(sem ramo)" : "`\(b)`", origin: "git", date: now)
        }
        if let log = await Self.git(["log", "-1", "--format=%s%x09%cI"], root)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !log.isEmpty {
            let parts = log.components(separatedBy: "\t")
            let when = parts.count > 1 ? ISO8601.parse(parts[1]) ?? now : now
            m.set(.commit, "\"\(parts[0])\"", origin: "git", date: when)
        }
        if let status = await Self.git(["status", "--porcelain", "--untracked-files=normal"], root) {
            let names = status.split(separator: "\n").compactMap { line -> String? in
                let s = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : (s.components(separatedBy: " -> ").last ?? s)
            }
            let shown = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " e mais \(names.count - 4)" : "")
            m.set(.changes, names.isEmpty ? nil : shown, origin: "git", date: now)
        }
    }

    static func git(_ args: [String], _ dir: String) async -> String? {
        guard let r = try? await Spawn.run(["/usr/bin/env", "git", "-C", dir] + args, environment: ShellTool.cleanEnvironment(), timeout: 10),
              r.status == 0 else { return nil }
        return r.output
    }

    /// Todos os marcadores (para `glyphd memoria`).
    public func all() -> [ProjectMarker] { repos.map(marker) }
}
