import Foundation

// Modo ensaio (proposta 0002, ideia 4): mostrar antes de executar.
//
// Um plano é só dado: passos com classe, origem e destino, mais os casos que
// precisam de você. Nada aqui toca o disco; quem executa é o `glyphd`, e só
// depois da aprovação.

/// Um arquivo visto na pasta, sem o conteúdo.
public struct FileEntry: Sendable, Codable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date

    public init(name: String, isDirectory: Bool = false, size: Int64 = 0, modified: Date = .distantPast) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// Um passo do plano. Caminhos relativos à pasta do plano.
public struct PlanStep: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case move = "mover", rename = "renomear", moveAndRename = "mover_renomear" }

    public var id: String
    public var kind: Kind
    public var from: String
    public var to: String
    public var actionClass: ActionClass

    public init(id: String, kind: Kind, from: String, to: String, actionClass: ActionClass = .localWrite) {
        self.id = id
        self.kind = kind
        self.from = from
        self.to = to
        self.actionClass = actionClass
    }

    enum CodingKeys: String, CodingKey { case id, kind, from, to, actionClass = "class" }

    public var movesFolder: Bool { kind != .rename }
    public var renames: Bool { kind != .move }
}

/// Um caso que o Glyph não decide sozinho.
public struct PlanDecision: Sendable, Codable, Equatable, Identifiable {
    public enum Choice: String, Sendable, Codable, CaseIterable {
        /// Não mexe (o padrão: sem resposta, não mexe).
        case skip = "pular"
        /// Move mesmo assim, com um nome que não colide.
        case keepBoth = "manter_ambos"
        /// Move para o destino proposto (quando não há colisão).
        case move = "mover"
    }

    public var id: String
    public var path: String
    public var reason: String
    /// O que faria se você escolher mover.
    public var proposed: String?
    public var options: [Choice]
    public var choice: Choice?

    public init(id: String, path: String, reason: String, proposed: String? = nil, options: [Choice], choice: Choice? = nil) {
        self.id = id
        self.path = path
        self.reason = reason
        self.proposed = proposed
        self.options = options
        self.choice = choice
    }
}

/// Um plano de ensaio.
public struct RehearsalPlan: Sendable, Codable, Equatable, Identifiable {
    public enum Status: String, Sendable, Codable { case proposed = "proposto", applied = "aplicado", undone = "desfeito" }

    public var id: String
    public var title: String
    /// Pasta absoluta onde o plano vale. Nenhum passo sai dela.
    public var root: String
    public var created: Date
    public var steps: [PlanStep]
    public var decisions: [PlanDecision]
    /// Coisas vistas e deixadas como estão (pastas, ocultos).
    public var untouched: [String]
    public var status: Status

    public init(id: String, title: String, root: String, created: Date = Date(), steps: [PlanStep],
                decisions: [PlanDecision], untouched: [String] = [], status: Status = .proposed) {
        self.id = id
        self.title = title
        self.root = root
        self.created = created
        self.steps = steps
        self.decisions = decisions
        self.untouched = untouched
        self.status = status
    }

    public var movedCount: Int { steps.filter(\.movesFolder).count }
    public var renamedCount: Int { steps.filter(\.renames).count }
    public var pendingDecisions: [PlanDecision] { decisions.filter { $0.choice == nil } }

    /// Classes que o plano usa. Aprovar o plano só cobre as reversíveis.
    public var classes: Set<ActionClass> { Set(steps.map(\.actionClass)) }
    public var irreversibleSteps: [PlanStep] { steps.filter { $0.actionClass.isReversible == false } }

    /// "32 arquivos seriam movidos, 4 nomes mudariam, 3 casos precisam de decisão."
    public var summary: String {
        var parts: [String] = []
        let m = movedCount, r = renamedCount, d = decisions.count
        if m > 0 { parts.append(m == 1 ? "1 arquivo seria movido" : "\(m) arquivos seriam movidos") }
        if r > 0 { parts.append(r == 1 ? "1 nome mudaria" : "\(r) nomes mudariam") }
        if d > 0 { parts.append(d == 1 ? "1 caso precisa de decisão" : "\(d) casos precisam de decisão") }
        if parts.isEmpty { return "nada a mudar." }
        return Self.joinPT(parts) + "."
    }

    static func joinPT(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " e " + parts.last!
    }

    /// Os passos que valem depois das decisões (sem resposta = pular).
    public func effectiveSteps() -> [PlanStep] {
        var out = steps
        let taken = Set(steps.map { $0.to.lowercased() })
        var used = taken
        for d in decisions {
            guard let choice = d.choice, let proposed = d.proposed else { continue }
            switch choice {
            case .skip: continue
            case .move:
                guard d.options.contains(.move), !used.contains(proposed.lowercased()) else { continue }
                used.insert(proposed.lowercased())
                out.append(PlanStep(id: d.id, kind: FileOrganizer.kind(from: d.path, to: proposed), from: d.path, to: proposed))
            case .keepBoth:
                guard d.options.contains(.keepBoth) else { continue }
                let free = FileOrganizer.freeName(proposed, taken: used)
                used.insert(free.lowercased())
                out.append(PlanStep(id: d.id, kind: FileOrganizer.kind(from: d.path, to: free), from: d.path, to: free))
            }
        }
        return out
    }

    /// Linhas legíveis para o terminal e para a casa.
    public func preview(limit: Int = 12) -> [String] {
        var out = ["\(title): \(summary)"]
        let shown = steps.prefix(limit)
        for s in shown {
            out.append("  \(s.kind == .rename ? "renomear" : "mover")  \(s.from) → \(s.to)")
        }
        if steps.count > shown.count { out.append("  … e mais \(steps.count - shown.count)") }
        for d in decisions {
            let now = d.choice.map { " [\($0.rawValue)]" } ?? ""
            out.append("  ? \(d.id)  \(d.path): \(d.reason) (opções: \(d.options.map(\.rawValue).joined(separator: ", ")))\(now)")
        }
        return out
    }
}

/// Planeja a organização de uma pasta (ex.: Downloads). Só mover e renomear
/// dentro dela; nunca apagar, nunca sobrescrever, nunca entrar em subpastas.
public enum FileOrganizer {
    /// Pasta de destino por extensão.
    public static let categories: [(folder: String, extensions: Set<String>)] = [
        ("Imagens", ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp", "raw"]),
        ("PDFs", ["pdf"]),
        ("Documentos", ["doc", "docx", "odt", "rtf", "txt", "md", "pages", "epub"]),
        ("Planilhas", ["xls", "xlsx", "ods", "csv", "numbers", "tsv"]),
        ("Apresentações", ["ppt", "pptx", "odp", "key"]),
        ("Áudio", ["mp3", "wav", "aac", "m4a", "flac", "ogg", "aiff"]),
        ("Vídeos", ["mp4", "mov", "mkv", "avi", "webm", "m4v"]),
        ("Compactados", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
        ("Instaladores", ["dmg", "pkg", "app", "exe", "msi", "deb", "rpm"]),
        ("Código", ["swift", "py", "js", "ts", "json", "yaml", "yml", "html", "css", "sh", "rb", "go", "rs", "c", "h", "cpp"]),
    ]

    /// Download que ainda não terminou: não se mexe.
    static let incomplete: Set<String> = ["crdownload", "part", "download", "partial", "tmp"]

    public static func folder(for name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return categories.first { $0.extensions.contains(ext) }?.folder
    }

    /// Nome arrumado: capturas de tela com data legível, espaços simples,
    /// sem espaços nas pontas. Nunca muda a extensão.
    public static func tidyName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        var base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        // "Screenshot 2026-09-12 at 10.22.01", "Captura de Tela 2026-09-12 às 10.22.01"
        let pattern = #"^(?:Screen ?[Ss]hot|Captura de [Tt]ela|Captura de ecrã)\s+(\d{4}-\d{2}-\d{2})\s+(?:at|às|as|a las)\s+(\d{1,2})[.:](\d{2})[.:](\d{2})(.*)$"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
            func g(_ i: Int) -> String { Range(m.range(at: i), in: base).map { String(base[$0]) } ?? "" }
            let hour = g(2).count == 1 ? "0" + g(2) : g(2)
            let rest = g(5).trimmingCharacters(in: .whitespaces)
            base = "captura \(g(1)) \(hour)-\(g(3))-\(g(4))" + (rest.isEmpty ? "" : " \(rest)")
        }
        base = base.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" || $0 == "\u{202F}" })
            .joined(separator: " ")
        if base.isEmpty { return name }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    static func kind(from: String, to: String) -> PlanStep.Kind {
        let movedDir = (from as NSString).deletingLastPathComponent != (to as NSString).deletingLastPathComponent
        let renamed = (from as NSString).lastPathComponent != (to as NSString).lastPathComponent
        switch (movedDir, renamed) {
        case (true, true): return .moveAndRename
        case (false, true): return .rename
        default: return .move
        }
    }

    /// `nome (2).ext`, `nome (3).ext`… até não colidir.
    public static func freeName(_ path: String, taken: Set<String>) -> String {
        guard taken.contains(path.lowercased()) else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        let base = ext.isEmpty ? file : String(file.dropLast(ext.count + 1))
        for n in 2...999 {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let full = dir.isEmpty ? candidate : "\(dir)/\(candidate)"
            if !taken.contains(full.lowercased()) { return full }
        }
        return path
    }

    /// - Parameters:
    ///   - entries: o que há na pasta (um nível).
    ///   - existing: caminhos relativos que já existem nas subpastas de destino
    ///     (ex.: `PDFs/contrato.pdf`), para não sobrescrever.
    ///   - recentWindow: arquivo mexido há menos disto pode estar em uso.
    public static func plan(id: String, root: String, entries: [FileEntry], existing: Set<String> = [],
                            now: Date = Date(), recentWindow: TimeInterval = 120) -> RehearsalPlan {
        var steps: [PlanStep] = []
        var decisions: [PlanDecision] = []
        var untouched: [String] = []
        let categoryFolders = Set(categories.map(\.folder))
        // Tudo que existe ou vai existir, em minúsculas (APFS ignora caixa).
        var taken = Set(existing.map { $0.lowercased() })
        for e in entries { taken.insert(e.name.lowercased()) }
        var claimed: Set<String> = []

        func decide(_ path: String, _ reason: String, proposed: String?, _ options: [PlanDecision.Choice]) {
            decisions.append(PlanDecision(id: "c\(decisions.count + 1)", path: path, reason: reason, proposed: proposed, options: options))
        }

        for e in entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            if e.name.hasPrefix(".") { continue }
            if e.isDirectory {
                if !categoryFolders.contains(e.name) { untouched.append(e.name + "/") }
                continue
            }
            let ext = (e.name as NSString).pathExtension.lowercased()
            if incomplete.contains(ext) {
                untouched.append(e.name)
                continue
            }
            let tidy = tidyName(e.name)
            let dest: String
            if let f = folder(for: e.name) {
                dest = "\(f)/\(tidy)"
            } else if tidy != e.name {
                dest = tidy
            } else {
                // Sem categoria e com nome bom: fica onde está.
                if ext.isEmpty { decide(e.name, "sem extensão: não sei o que é", proposed: nil, [.skip]) }
                else { untouched.append(e.name) }
                continue
            }
            if now.timeIntervalSince(e.modified) < recentWindow {
                decide(e.name, "mexido há pouco: pode estar em uso", proposed: dest, [.skip, .move])
                continue
            }
            let key = dest.lowercased()
            if claimed.contains(key) || (taken.contains(key) && key != e.name.lowercased()) {
                decide(e.name, "já existe \(dest)", proposed: dest, [.skip, .keepBoth])
                continue
            }
            claimed.insert(key)
            taken.insert(key)
            steps.append(PlanStep(id: "p\(steps.count + 1)", kind: kind(from: e.name, to: dest), from: e.name, to: dest))
        }
        let name = (root as NSString).lastPathComponent
        return RehearsalPlan(id: id, title: "organizar \(name)", root: root, created: now, steps: steps,
                             decisions: decisions, untouched: untouched)
    }

    /// Um caminho relativo seguro: sem `..`, sem absoluto, sem oculto.
    public static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." || $0.hasPrefix(".") }
    }
}
