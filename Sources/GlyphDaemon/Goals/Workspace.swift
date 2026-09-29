import Foundation
import GlyphCore

/// Onde uma tarefa trabalha: um worktree git num ramo `glyph/*` (nunca a
/// main), ou uma pasta com checkpoint prévio em `casa/journal/<id>/`.
public struct Workspace: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case worktree(repo: String, branch: String), checkpoint(original: String, backup: String) }

    public var path: String
    public var kind: Kind

    public var branch: String? {
        if case let .worktree(_, b) = kind { return b }
        return nil
    }
}

public enum WorkspaceManager {
    static let gitIdentity = ["-c", "user.name=Glyph", "-c", "user.email=glyph@localhost", "-c", "commit.gpgsign=false"]

    @discardableResult
    static func git(_ args: [String], in dir: String, timeout: TimeInterval = 60) async throws -> Spawn.Result {
        try await Spawn.run(["/usr/bin/env", "git", "-C", dir] + gitIdentity + args,
                            environment: ShellTool.cleanEnvironment(), timeout: timeout)
    }

    static func branchName(_ taskID: String) -> String {
        "glyph/" + taskID.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.reduce("") { $0 + String($1) }
    }

    /// Cria (ou reaproveita) o espaço de trabalho da tarefa.
    public static func prepare(scope: String, taskID: String, casa: GlyphPaths) async throws -> Workspace {
        let dir = ShellTool.expand(scope)
        if let repo = GitWatcher.root(of: dir) {
            let branch = branchName(taskID)
            let path = casa.casa.appendingPathComponent("worktrees/\((repo as NSString).lastPathComponent)-\(taskID)").path
            if FileManager.default.fileExists(atPath: path) {
                return Workspace(path: path, kind: .worktree(repo: repo, branch: branch))
            }
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let exists = try await git(["rev-parse", "--verify", "--quiet", branch], in: repo).status == 0
            let r = try await git(exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path, "HEAD"], in: repo)
            guard r.status == 0 else { throw ToolError.failed("git worktree falhou: \(r.output)") }
            return Workspace(path: path, kind: .worktree(repo: repo, branch: branch))
        }
        // Sem git: copia antes de mexer.
        let backup = casa.journal.appendingPathComponent(taskID).path
        if !FileManager.default.fileExists(atPath: backup) {
            try FileManager.default.createDirectory(atPath: casa.journal.path, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: dir, toPath: backup)
        }
        return Workspace(path: dir, kind: .checkpoint(original: dir, backup: backup))
    }

    /// Descarta mudanças da tentativa que falhou (só no espaço do Glyph).
    public static func discardChanges(_ w: Workspace) async throws {
        switch w.kind {
        case .worktree:
            try await git(["reset", "--hard", "-q"], in: w.path)
            try await git(["clean", "-fdq"], in: w.path)
        case let .checkpoint(original, backup):
            try restore(original: original, backup: backup)
        }
    }

    /// Registra o que deu certo como commit no ramo `glyph/*`.
    public static func commit(_ w: Workspace, message: String) async throws -> Bool {
        guard case .worktree = w.kind else { return true }
        try await git(["add", "-A"], in: w.path)
        let r = try await git(["commit", "-q", "-m", message], in: w.path)
        return r.status == 0
    }

    public static func restore(original: String, backup: String) throws {
        let fm = FileManager.default
        let tmp = original + ".glyph-restaurando"
        try? fm.removeItem(atPath: tmp)
        try fm.copyItem(atPath: backup, toPath: tmp)
        try fm.removeItem(atPath: original)
        try fm.moveItem(atPath: tmp, toPath: original)
    }
}

/// Lê um arquivo dentro das pastas permitidas.
public struct ReadFileTool: Tool {
    public var roots: [String]
    public var maxBytes: Int

    public init(roots: [String], maxBytes: Int = 60_000) {
        self.roots = roots.map { ShellTool.expand($0) }
        self.maxBytes = maxBytes
    }

    public var spec: ToolSpec {
        ToolSpec(name: "read_file", description: "Lê um arquivo de texto (caminho relativo à pasta de trabalho).",
                 inputSchema: schema([("path", "Caminho do arquivo", true)]))
    }

    public var actionClass: ActionClass { .read }
    public var place: ToolPlace { .editor }
    public func scope(_ input: JSONValue) -> String { Scope.normalize(roots.first ?? "*") }
    public func summarize(_ input: JSONValue) -> String { "ler " + (input["path"]?.stringValue ?? "") }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let url = try FilePaths.resolve(input["path"]?.stringValue, roots: roots)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data.prefix(maxBytes), as: UTF8.self)
        return ToolOutput(markUntrusted(text + (data.count > maxBytes ? "\n[cortado]" : ""), source: url.lastPathComponent),
                          untrusted: true)
    }
}

/// Escreve um arquivo dentro das pastas permitidas (no worktree da tarefa).
public struct WriteFileTool: Tool {
    public var roots: [String]

    public init(roots: [String]) { self.roots = roots.map { ShellTool.expand($0) } }

    public var spec: ToolSpec {
        ToolSpec(name: "write_file", description: "Escreve (substitui) um arquivo de texto na pasta de trabalho.",
                 inputSchema: schema([("path", "Caminho do arquivo", true), ("content", "Conteúdo completo", true)]))
    }

    public var actionClass: ActionClass { .localWrite }
    public var place: ToolPlace { .editor }
    public func scope(_ input: JSONValue) -> String { Scope.normalize(roots.first ?? "*") }
    public func summarize(_ input: JSONValue) -> String { "escrever " + (input["path"]?.stringValue ?? "") }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let url = try FilePaths.resolve(input["path"]?.stringValue, roots: roots)
        guard let content = input["content"]?.stringValue else { throw ToolError.badInput("falta content") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        return ToolOutput("escrito: \(url.lastPathComponent) (\(content.utf8.count) bytes)")
    }
}

enum FilePaths {
    /// Resolve um caminho relativo à primeira pasta e confere que não escapa das permitidas.
    static func resolve(_ path: String?, roots: [String]) throws -> URL {
        guard let path, !path.isEmpty, let base = roots.first else { throw ToolError.badInput("falta path") }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: base).appendingPathComponent(path)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard roots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) else {
            throw ToolError.forbidden("fora da pasta de trabalho: \(path)")
        }
        if resolved.split(separator: "/").contains(".git") { throw ToolError.forbidden("não mexe em .git") }
        return URL(fileURLWithPath: resolved)
    }
}
