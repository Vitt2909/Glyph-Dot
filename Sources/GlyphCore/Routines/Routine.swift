import Foundation

// Ensinar mostrando (proposta 0002, ideia 2).
//
// Você demonstra uma sequência no terminal; o Glyph anota comando, pasta e
// código de saída (nunca a saída) e prepara um rascunho de rotina com
// parâmetros e a classe de cada passo. Aprender não autoriza nada: o
// rascunho só vale depois da sua aprovação, cada execução passa pela
// política, e a primeira execução com cada conjunto de parâmetros é ensaio.

/// Um comando visto durante a demonstração.
public struct DemoStep: Sendable, Codable, Equatable {
    public var command: String
    public var cwd: String
    public var code: Int

    public init(command: String, cwd: String, code: Int) {
        self.command = command
        self.cwd = cwd
        self.code = code
    }
}

public struct RoutineStep: Sendable, Codable, Equatable {
    /// Com `{parametro}` no lugar dos valores do exemplo.
    public var command: String
    public var cwd: String
    public var actionClass: ActionClass
    /// Proibido mesmo com aprovação (sudo…): fica de fora ao rodar.
    public var forbidden: Bool

    enum CodingKeys: String, CodingKey { case command, cwd, actionClass = "class", forbidden }

    public init(command: String, cwd: String, actionClass: ActionClass, forbidden: Bool = false) {
        self.command = command
        self.cwd = cwd
        self.actionClass = actionClass
        self.forbidden = forbidden
    }

    public var isIrreversible: Bool { actionClass.isReversible == false }
}

public struct Routine: Sendable, Codable, Equatable {
    public var name: String
    /// Parâmetro → valor do exemplo demonstrado.
    public var parameters: [String: String]
    public var steps: [RoutineStep]
    public var created: Date
    public var approved: Bool
    /// Parâmetros já ensaiados (a primeira execução com eles é sempre ensaio).
    public var rehearsed: [[String: String]]
    /// Palavras que se repetem e talvez devessem ser parâmetro.
    public var suggestions: [String]?

    public init(name: String, parameters: [String: String], steps: [RoutineStep], created: Date = Date(),
                approved: Bool = false, rehearsed: [[String: String]] = []) {
        self.name = name
        self.parameters = parameters
        self.steps = steps
        self.created = created
        self.approved = approved
        self.rehearsed = rehearsed
    }

    /// Comandos que não fazem parte da rotina (navegação, consulta).
    static let noise: Set<String> = ["cd", "ls", "pwd", "clear", "history", "exit", "echo", "cat", "less", "man", "which", "open"]

    static func firstWord(_ cmd: String) -> String {
        cmd.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
    }

    /// Monta o rascunho a partir da demonstração. `parameters`: nome → valor
    /// que você disse ao começar (ex.: cliente=acme).
    public static func draft(name: String, demo: [DemoStep], parameters: [String: String], created: Date = Date()) -> Routine {
        let kept = demo.filter { $0.code == 0 && !noise.contains(firstWord($0.command)) }
        // Valores mais longos primeiro, para "acme-corp" não virar "{cliente}-corp".
        let subs = parameters.filter { !$0.value.isEmpty }.sorted { $0.value.count > $1.value.count }
        func generalize(_ s: String) -> String {
            subs.reduce(s) { $0.replacingOccurrences(of: $1.value, with: "{\($1.key)}") }
        }
        let steps = kept.map { d -> RoutineStep in
            let v = CommandClassifier.classify(d.command)
            return RoutineStep(command: generalize(d.command), cwd: generalize(d.cwd), actionClass: v.actionClass, forbidden: v.forbidden)
        }
        var r = Routine(name: name, parameters: parameters, steps: steps, created: created)
        if parameters.isEmpty {
            let s = suggestParameters(kept)
            if !s.isEmpty { r.suggestions = s }
        }
        return r
    }

    /// Palavras que aparecem em mais de um passo e podem ser parâmetro.
    public static func suggestParameters(_ demo: [DemoStep]) -> [String] {
        // Conta mais o que aparece nos comandos do que nas pastas.
        var score: [String: Int] = [:]
        func words(_ s: String) -> Set<String> {
            Set(s.split(whereSeparator: { " /.-_=\"'~".contains($0) }).map(String.init)
                .filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) })
        }
        for d in demo where d.code == 0 {
            for w in words(d.command) { score[w, default: 0] += 2 }
            for w in words(d.cwd) { score[w, default: 0] += 1 }
        }
        let common: Set<String> = ["Users", "home", "dev", "git", "swift", "npm", "run", "build", "test", "the", "src", "Sources",
                                   "mkdir", "touch", "cp", "mv", "pdf", "txt", "md"]
        return score.filter { $0.value >= 3 && !common.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map(\.key)
    }

    /// Os passos com os valores desta execução. Falta parâmetro → `nil`.
    public func instantiate(_ values: [String: String]) -> [RoutineStep]? {
        guard parameters.keys.allSatisfy({ values[$0].map { !$0.isEmpty } ?? false }) else { return nil }
        // Valor de parâmetro nunca carrega sintaxe de shell.
        guard values.values.allSatisfy(Self.isSafeValue) else { return nil }
        return steps.map { s in
            var out = s
            for (k, v) in values {
                out.command = out.command.replacingOccurrences(of: "{\(k)}", with: v)
                out.cwd = out.cwd.replacingOccurrences(of: "{\(k)}", with: v)
            }
            let verdict = CommandClassifier.classify(out.command)
            out.actionClass = CommandClassifier.max(out.actionClass, verdict.actionClass)
            out.forbidden = out.forbidden || verdict.forbidden
            return out
        }
    }

    /// Letras, números, espaço, `-`, `_`, `.`, `@`. Nada de `;`, `$`, aspas, `/`.
    public static func isSafeValue(_ v: String) -> Bool {
        !v.isEmpty && v.count <= 80 && !v.hasPrefix("-") && !v.contains("..")
            && v.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || " -_.@".unicodeScalars.contains($0) }
    }

    public func wasRehearsed(_ values: [String: String]) -> Bool { rehearsed.contains(values) }

    /// A classe mais arriscada da rotina.
    public var worstClass: ActionClass {
        steps.map(\.actionClass).reduce(ActionClass.read) { CommandClassifier.max($0, $1) }
    }

    public var hasIrreversible: Bool { steps.contains(where: \.isIrreversible) }

    public static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 48 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// O que você vê antes de aprovar: passos, parâmetros e permissões.
    public func render() -> String {
        var out = "# Rotina: \(name)\n\n"
        out += approved ? "> Ativa (aprovada).\n\n"
            : "> Rascunho. Só vira rotina ativa com a sua aprovação: `glyphd rotina aprovar \(name)`.\n\n"
        out += "Parâmetros: " + (parameters.isEmpty ? "nenhum" : parameters.sorted { $0.key < $1.key }
            .map { "`\($0.key)` (exemplo: \($0.value))" }.joined(separator: ", ")) + "\n\n"
        if let s = suggestions, !s.isEmpty {
            out += "Talvez sejam parâmetros: \(s.joined(separator: ", ")). Para usar, ensine de novo com "
                + "`/ensinar \(name) nome=\(s[0])`.\n\n"
        }
        out += "Passos:\n\n"
        for (i, s) in steps.enumerated() {
            let note = s.forbidden ? " — **proibido: fica de fora**"
                : (s.isIrreversible ? " — pede cartão a cada execução" : "")
            out += "\(i + 1). `\(s.command)` em `\(s.cwd)` · \(s.actionClass.rawValue)\(note)\n"
        }
        let classes = Set(steps.map(\.actionClass.rawValue)).sorted().joined(separator: ", ")
        out += "\nPermissões que ela usa: \(classes.isEmpty ? "nenhuma" : classes). "
        out += "Cada passo passa pela política; a primeira execução com novos parâmetros é um ensaio.\n"
        return out
    }
}
