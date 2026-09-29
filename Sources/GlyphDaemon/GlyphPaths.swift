import Foundation

/// Onde o Glyph guarda as coisas. Tudo fica dentro de
/// `~/Library/Application Support/Glyph/` (docs/ARCHITECTURE.md, "a casa").
public struct GlyphPaths: Sendable, Equatable {
    public var support: URL

    public init(support: URL) { self.support = support }

    /// Raiz padrão. `GLYPH_HOME` sobrescreve (útil em testes e no Linux).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> GlyphPaths {
        if let custom = environment["GLYPH_HOME"], !custom.isEmpty {
            return GlyphPaths(support: URL(fileURLWithPath: custom, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GlyphPaths(support: home
            .appendingPathComponent("Library/Application Support/Glyph", isDirectory: true))
    }

    public var socket: URL { support.appendingPathComponent("glyphd.sock") }
    public var casa: URL { support.appendingPathComponent("casa", isDirectory: true) }
    public var memoria: URL { casa.appendingPathComponent("memoria", isDirectory: true) }
    public var skills: URL { casa.appendingPathComponent("skills", isDirectory: true) }
    public var skillDrafts: URL { skills.appendingPathComponent("_rascunhos", isDirectory: true) }
    public var diario: URL { casa.appendingPathComponent("diario", isDirectory: true) }
    public var journal: URL { casa.appendingPathComponent("journal", isDirectory: true) }
    public var database: URL { casa.appendingPathComponent("glyph.sqlite") }
    public var goals: URL { casa.appendingPathComponent("goals.yaml") }
    public var policy: URL { casa.appendingPathComponent("policy.yaml") }

    /// Cria a estrutura da casa (idempotente). Permissões 0700: é memória pessoal.
    public func ensureCasa(fileManager fm: FileManager = .default) throws {
        for dir in [support, casa, memoria, skills, skillDrafts, diario, journal] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }
}
