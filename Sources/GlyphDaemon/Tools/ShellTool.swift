import Foundation
import GlyphCore

/// Shell em sandbox: só em pastas permitidas, sem `sudo`, ambiente limpo,
/// timeout e saída limitada. No macOS, `sandbox-exec` ainda bloqueia escrita
/// fora das pastas permitidas.
public struct ShellTool: Tool {
    public struct Config: Sendable, Equatable {
        public var allowedRoots: [String]
        public var timeout: TimeInterval
        public var maxOutput: Int
        public var useSandboxExec: Bool

        public init(allowedRoots: [String], timeout: TimeInterval = 60, maxOutput: Int = 16_000,
                    useSandboxExec: Bool = true) {
            self.allowedRoots = allowedRoots.map { ShellTool.expand($0) }
            self.timeout = timeout
            self.maxOutput = maxOutput
            self.useSandboxExec = useSandboxExec
        }
    }

    public var config: Config

    public init(config: Config) { self.config = config }

    public var spec: ToolSpec {
        ToolSpec(name: "shell",
                 description: "Roda um comando de shell numa pasta permitida (\(config.allowedRoots.joined(separator: ", "))). "
                    + "Sem sudo. Timeout de \(Int(config.timeout)) s. Devolve saída e código de saída.",
                 inputSchema: schema([("command", "Comando de shell", true),
                                      ("cwd", "Pasta de trabalho (dentro das permitidas)", false)]))
    }

    public var actionClass: ActionClass { .externalEffect }
    public var place: ToolPlace { .terminal }

    public func classify(_ input: JSONValue) -> ActionClass {
        CommandClassifier.classify(input["command"]?.stringValue ?? "").actionClass
    }

    public func summarize(_ input: JSONValue) -> String {
        "$ " + (input["command"]?.stringValue ?? "")
    }

    static func expand(_ path: String) -> String {
        let p = path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
        return URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A pasta está dentro de alguma permitida?
    public func isAllowed(_ dir: String) -> Bool {
        let d = Self.expand(dir)
        return config.allowedRoots.contains { root in d == root || d.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        guard let command = input["command"]?.stringValue, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.badInput("falta command")
        }
        let verdict = CommandClassifier.classify(command)
        if verdict.forbidden { throw ToolError.forbidden(verdict.reason) }
        guard let first = config.allowedRoots.first else { throw ToolError.forbidden("nenhuma pasta permitida") }
        let cwd = Self.expand(input["cwd"]?.stringValue ?? first)
        guard isAllowed(cwd) else { throw ToolError.forbidden("pasta fora das permitidas: \(cwd)") }
        guard FileManager.default.fileExists(atPath: cwd) else { throw ToolError.badInput("pasta não existe: \(cwd)") }

        let result = try await Self.execute(command: command, cwd: cwd, config: config)
        var text = result.output
        if text.utf8.count > config.maxOutput {
            text = String(decoding: text.utf8.suffix(config.maxOutput), as: UTF8.self)
            text = "[saída cortada; últimos \(config.maxOutput) bytes]\n" + text
        }
        let status = result.timedOut ? "tempo esgotado" : "código de saída \(result.status)"
        return ToolOutput(markUntrusted(text, source: "shell") + "\n(\(status))",
                          isError: result.status != 0 || result.timedOut, untrusted: true)
    }

    struct Execution: Sendable {
        var output: String
        var status: Int32
        var timedOut: Bool
    }

    /// Ambiente limpo: só o necessário, sem segredos herdados.
    static func cleanEnvironment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out: [String: String] = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": env["LANG"] ?? "pt_BR.UTF-8",
            "TERM": "dumb",
            "NO_COLOR": "1",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if let user = env["USER"] { out["USER"] = user }
        return out
    }

    static func sandboxProfile(roots: [String]) -> String {
        let writable = (roots + ["/private/tmp", "/private/var/folders", "/dev"]).map { #"(subpath "\#($0)")"# }.joined(separator: " ")
        return "(version 1)(allow default)(deny file-write* (require-not (require-any \(writable))))"
    }

    static func execute(command: String, cwd: String, config: Config) async throws -> Execution {
        // A pasta entra com aspas simples escapadas; o comando roda depois do cd.
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "cd \(quoted) && \(command)"
        var argv = ["/bin/sh", "-c", script]
        #if os(macOS)
        if config.useSandboxExec, FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            argv = ["/usr/bin/sandbox-exec", "-p", sandboxProfile(roots: config.allowedRoots)] + argv
        }
        #endif
        let r = try await Spawn.run(argv, environment: cleanEnvironment(), timeout: config.timeout)
        return Execution(output: r.output, status: r.status, timedOut: r.timedOut)
    }
}
