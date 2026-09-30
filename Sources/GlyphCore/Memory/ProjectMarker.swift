import Foundation

// Retomada de projetos (proposta 0002, ideia 5).
//
// Um marcador por projeto, em Markdown legível e editável, com fatos no
// formato "fato · origem · data". Fatos vêm de metadados (git, códigos de
// saída, arquivo:linha): nunca saída de terminal nem texto de arquivo. O que
// você escreve (origem "você") nunca é sobrescrito. Memória é dado: nada
// aqui vira instrução.

public struct ProjectFact: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case branch = "ramo"
        case commit = "commit"
        case changes = "mexidos"
        case failing = "falhando"
        case passing = "passando"
        case note = "nota"
    }

    public var kind: Kind
    public var text: String
    public var origin: String
    public var date: Date

    public init(_ kind: Kind, _ text: String, origin: String, date: Date) {
        self.kind = kind
        self.text = text
        self.origin = origin
        self.date = date
    }

    /// Escrito por você (nota): nunca é trocado por fato automático.
    public var isYours: Bool { kind == .note || origin == "você" }
}

public struct ProjectMarker: Sendable, Equatable {
    public var name: String
    public var root: String
    public var facts: [ProjectFact]

    public init(name: String, root: String, facts: [ProjectFact] = []) {
        self.name = name
        self.root = root
        self.facts = facts
    }

    public static let header = "<!-- marcador do Glyph. Cada linha: tipo: fato · origem · data. Edite ou apague à vontade; linhas de origem \"você\" nunca são trocadas. -->"

    public func fact(_ k: ProjectFact.Kind) -> ProjectFact? { facts.last { $0.kind == k } }

    /// Troca os fatos automáticos de um tipo (as notas ficam).
    public mutating func set(_ k: ProjectFact.Kind, _ text: String?, origin: String, date: Date) {
        facts.removeAll { $0.kind == k && !$0.isYours }
        if let text, !text.isEmpty { facts.append(ProjectFact(k, Self.clean(text), origin: origin, date: date)) }
    }

    public mutating func addNote(_ text: String, date: Date) {
        facts.append(ProjectFact(.note, Self.clean(text), origin: "você", date: date))
    }

    /// Uma linha, só com fatos: o que falta ou onde parou.
    public var resumeLine: String? {
        if let n = facts.last(where: { $0.kind == .note }) { return "\(name): \(n.text)" }
        if let f = fact(.failing) { return "\(name): falta \(f.text)" }
        if let c = fact(.changes) { return "\(name): mexendo em \(c.text)" }
        if let b = fact(.branch), b.text != "main", b.text != "master" { return "\(name): no ramo \(b.text)" }
        return nil
    }

    // MARK: - Markdown

    public func render() -> String {
        var out = "# \(name)\n\n\(Self.header)\n\npasta: \(root)\n\n"
        for f in facts {
            out += "- \(f.kind.rawValue): \(f.text) · \(f.origin) · \(Self.format(f.date))\n"
        }
        return out
    }

    public static func parse(_ text: String) -> ProjectMarker? {
        var name: String?
        var root = ""
        var facts: [ProjectFact] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# "), name == nil { name = String(line.dropFirst(2)); continue }
            if line.hasPrefix("pasta: ") { root = String(line.dropFirst(7)); continue }
            guard line.hasPrefix("- ") else { continue }
            let body = line.dropFirst(2)
            let parts = body.components(separatedBy: " · ")
            guard parts.count >= 3, let colon = parts[0].firstIndex(of: ":") else { continue }
            let kindRaw = String(parts[0][..<colon])
            let factText = parts[0][parts[0].index(after: colon)...].trimmingCharacters(in: .whitespaces)
                + (parts.count > 3 ? " · " + parts[1..<(parts.count - 2)].joined(separator: " · ") : "")
            let kind = ProjectFact.Kind(rawValue: kindRaw) ?? .note
            let date = parse(date: parts[parts.count - 1]) ?? .distantPast
            facts.append(ProjectFact(kind, factText, origin: parts[parts.count - 2], date: date))
        }
        guard let name else { return nil }
        return ProjectMarker(name: name, root: root, facts: facts)
    }

    static func clean(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: " · ", with: " - ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }

    static func format(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    static func parse(date s: String) -> Date? {
        let p = s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        guard p.count == 5 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4]))
    }
}
