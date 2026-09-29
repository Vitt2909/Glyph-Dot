import Foundation

/// Um valor YAML já interpretado.
public indirect enum YAMLValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([YAMLValue])
    case object([String: YAMLValue])

    public subscript(key: String) -> YAMLValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        switch self {
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        case let .bool(b): return String(b)
        default: return nil
        }
    }

    /// Representação compatível com `JSONSerialization`.
    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .int(i): return i
        case let .double(d): return d
        case let .string(s): return s
        case let .array(a): return a.map(\.jsonObject)
        case let .object(o): return o.mapValues(\.jsonObject)
        }
    }
}

public struct YAMLError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String

    public var description: String { "linha \(line): \(message)" }
}

/// Um leitor de YAML pequeno, sem dependências, para os arquivos da casa
/// (`config.yaml`, `goals.yaml`, `policy.yaml`).
///
/// Suporta o que esses arquivos usam: mapas e listas por indentação,
/// listas de mapas (`- id: x`), escalares simples e entre aspas, coleções
/// em linha (`[a, b]`, `{k: v}`), comentários com `#` e blocos `|` e `>`.
/// Não suporta âncoras, tags nem múltiplos documentos: se aparecerem, é erro.
public enum MiniYAML {
    struct Line {
        var number: Int
        var indent: Int
        var text: String
    }

    public static func parse(_ source: String) throws -> YAMLValue {
        var lines: [Line] = []
        for (i, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let rawLine = String(raw).replacingOccurrences(of: "\r", with: "")
            if rawLine.hasPrefix("\t") || rawLine.drop(while: { $0 == " " }).hasPrefix("\t") {
                throw YAMLError(line: i + 1, message: "tabulação na indentação")
            }
            let indent = rawLine.prefix(while: { $0 == " " }).count
            let text = stripComment(String(rawLine.dropFirst(indent)))
            if text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(Line(number: i + 1, indent: -1, text: "")); continue }
            if text == "---" || text == "..." { continue }
            if text.hasPrefix("&") || text.hasPrefix("*") || text.hasPrefix("!") {
                throw YAMLError(line: i + 1, message: "âncoras e tags não são suportadas")
            }
            lines.append(Line(number: i + 1, indent: indent, text: text.trimmingCharacters(in: .whitespaces)))
        }
        var p = Parser(lines: lines)
        p.skipBlank()
        guard p.index < p.lines.count else { return .null }
        let v = try p.parseBlock(indent: p.lines[p.index].indent)
        p.skipBlank()
        if p.index < p.lines.count {
            throw YAMLError(line: p.lines[p.index].number, message: "indentação inesperada")
        }
        return v
    }

    /// Decodifica direto para um tipo `Decodable` (via JSON).
    public static func decode<T: Decodable>(_ type: T.Type, from source: String) throws -> T {
        let value = try parse(source)
        let data = try JSONSerialization.data(withJSONObject: value.jsonObject, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Remove comentários `#` fora de aspas (precedidos de espaço ou no início).
    static func stripComment(_ s: String) -> String {
        var inSingle = false, inDouble = false
        var prev: Character = " "
        var out = ""
        for ch in s {
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle && prev != "\\" { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble && (prev == " " || out.isEmpty) { break }
            out.append(ch)
            prev = ch
        }
        return out.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    struct Parser {
        var lines: [Line]
        var index = 0

        mutating func skipBlank() {
            while index < lines.count, lines[index].indent < 0 { index += 1 }
        }

        mutating func parseBlock(indent: Int) throws -> YAMLValue {
            skipBlank()
            guard index < lines.count else { return .null }
            if lines[index].text == "-" || lines[index].text.hasPrefix("- ") {
                return try parseList(indent: indent)
            }
            return try parseMap(indent: indent)
        }

        mutating func parseList(indent: Int) throws -> YAMLValue {
            var items: [YAMLValue] = []
            while true {
                skipBlank()
                guard index < lines.count, lines[index].indent == indent,
                      lines[index].text == "-" || lines[index].text.hasPrefix("- ") else { break }
                let line = lines[index]
                let rest = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    index += 1
                    skipBlank()
                    if index < lines.count, lines[index].indent > indent {
                        items.append(try parseBlock(indent: lines[index].indent))
                    } else {
                        items.append(.null)
                    }
                } else if MiniYAML.splitKey(rest) != nil {
                    // "- chave: valor" abre um mapa cujo recuo é o do texto depois do "- ".
                    let inner = indent + 2 + (line.text.dropFirst(2).prefix(while: { $0 == " " }).count)
                    lines[index] = Line(number: line.number, indent: inner, text: rest)
                    items.append(try parseMap(indent: inner))
                } else {
                    index += 1
                    items.append(try MiniYAML.scalarOrFlow(rest, line: line.number))
                }
            }
            return .array(items)
        }

        mutating func parseMap(indent: Int) throws -> YAMLValue {
            var obj: [String: YAMLValue] = [:]
            while true {
                skipBlank()
                guard index < lines.count else { break }
                let line = lines[index]
                if line.indent < indent { break }
                if line.indent > indent { throw YAMLError(line: line.number, message: "indentação inesperada") }
                if line.text.hasPrefix("- ") || line.text == "-" { break }
                guard let (key, rest) = MiniYAML.splitKey(line.text) else {
                    throw YAMLError(line: line.number, message: "esperava 'chave: valor'")
                }
                if obj[key] != nil { throw YAMLError(line: line.number, message: "chave repetida: \(key)") }
                index += 1
                if rest.isEmpty {
                    skipBlank()
                    if index < lines.count, lines[index].indent > indent {
                        obj[key] = try parseBlock(indent: lines[index].indent)
                    } else if index < lines.count, lines[index].indent == indent,
                              lines[index].text.hasPrefix("- ") || lines[index].text == "-" {
                        // Lista no mesmo recuo da chave (estilo comum).
                        obj[key] = try parseList(indent: indent)
                    } else {
                        obj[key] = .null
                    }
                } else if rest == "|" || rest == ">" || rest == "|-" || rest == ">-" {
                    obj[key] = .string(blockScalar(style: rest, parentIndent: indent))
                } else {
                    obj[key] = try MiniYAML.scalarOrFlow(rest, line: line.number)
                }
            }
            return .object(obj)
        }

        mutating func blockScalar(style: String, parentIndent: Int) -> String {
            var collected: [String] = []
            var blockIndent: Int?
            while index < lines.count {
                let l = lines[index]
                if l.indent < 0 { collected.append(""); index += 1; continue }
                if l.indent <= parentIndent { break }
                if blockIndent == nil { blockIndent = l.indent }
                collected.append(String(repeating: " ", count: max(0, l.indent - blockIndent!)) + l.text)
                index += 1
            }
            while collected.last == "" { collected.removeLast() }
            let body = style.hasPrefix("|") ? collected.joined(separator: "\n")
                                            : collected.joined(separator: " ")
            return style.hasSuffix("-") ? body : body + "\n"
        }
    }

    /// Divide "chave: resto". Aceita "chave:" no fim. Ignora ':' dentro de aspas
    /// e ':' sem espaço depois (ex.: "07:30").
    static func splitKey(_ s: String) -> (String, String)? {
        if s.hasPrefix("[") || s.hasPrefix("{") { return nil }
        var inSingle = false, inDouble = false
        let chars = Array(s)
        for i in chars.indices {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle() }
            if c == "\"" && !inSingle { inDouble.toggle() }
            if c == ":" && !inSingle && !inDouble && (i + 1 == chars.count || chars[i + 1] == " ") {
                var key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                if key.count >= 2, (key.first == "\"" && key.last == "\"") || (key.first == "'" && key.last == "'") {
                    key = String(key.dropFirst().dropLast())
                }
                guard !key.isEmpty else { return nil }
                return (key, String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func scalarOrFlow(_ s: String, line: Int) throws -> YAMLValue {
        if s.hasPrefix("[") || s.hasPrefix("{") {
            var f = FlowParser(chars: Array(s), line: line)
            let v = try f.parseValue()
            f.skipSpaces()
            guard f.i == f.chars.count else { throw YAMLError(line: line, message: "sobrou texto depois da coleção") }
            return v
        }
        return try scalar(s, line: line)
    }

    static func scalar(_ raw: String, line: Int) throws -> YAMLValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") {
            guard s.count >= 2, s.hasSuffix("\"") else { throw YAMLError(line: line, message: "aspas não fechadas") }
            return .string(unescape(String(s.dropFirst().dropLast())))
        }
        if s.hasPrefix("'") {
            guard s.count >= 2, s.hasSuffix("'") else { throw YAMLError(line: line, message: "aspas não fechadas") }
            return .string(String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE", "yes", "Yes": return .bool(true)
        case "false", "False", "FALSE", "no", "No": return .bool(false)
        default: break
        }
        if let i = Int(s.replacingOccurrences(of: "_", with: "")), s.first.map({ $0.isNumber || $0 == "-" || $0 == "+" }) == true {
            return .int(i)
        }
        if let d = Double(s), s.contains("."), s.first.map({ $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." }) == true {
            return .double(d)
        }
        return .string(s)
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default: out.append("\\"); out.append(n)
            }
        }
        return out
    }

    struct FlowParser {
        var chars: [Character]
        var line: Int
        var i = 0

        mutating func skipSpaces() { while i < chars.count, chars[i] == " " { i += 1 } }

        mutating func parseValue() throws -> YAMLValue {
            skipSpaces()
            guard i < chars.count else { throw YAMLError(line: line, message: "coleção incompleta") }
            if chars[i] == "[" {
                i += 1
                var items: [YAMLValue] = []
                skipSpaces()
                if i < chars.count, chars[i] == "]" { i += 1; return .array([]) }
                while true {
                    items.append(try parseValue())
                    skipSpaces()
                    guard i < chars.count else { throw YAMLError(line: line, message: "']' faltando") }
                    if chars[i] == "," { i += 1; continue }
                    if chars[i] == "]" { i += 1; return .array(items) }
                    throw YAMLError(line: line, message: "esperava ',' ou ']'")
                }
            }
            if chars[i] == "{" {
                i += 1
                var obj: [String: YAMLValue] = [:]
                skipSpaces()
                if i < chars.count, chars[i] == "}" { i += 1; return .object([:]) }
                while true {
                    skipSpaces()
                    let key = try token(stopAt: [":"])
                    guard i < chars.count, chars[i] == ":" else { throw YAMLError(line: line, message: "':' faltando") }
                    i += 1
                    obj[key.trimmingCharacters(in: .whitespaces)] = try parseValue()
                    skipSpaces()
                    guard i < chars.count else { throw YAMLError(line: line, message: "'}' faltando") }
                    if chars[i] == "," { i += 1; continue }
                    if chars[i] == "}" { i += 1; return .object(obj) }
                    throw YAMLError(line: line, message: "esperava ',' ou '}'")
                }
            }
            return try MiniYAML.scalar(try token(stopAt: [",", "]", "}"]), line: line)
        }

        mutating func token(stopAt: Set<Character>) throws -> String {
            skipSpaces()
            var out = ""
            if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                let q = chars[i]
                out.append(q)
                i += 1
                while i < chars.count, chars[i] != q {
                    if chars[i] == "\\", q == "\"", i + 1 < chars.count { out.append(chars[i]); i += 1 }
                    out.append(chars[i]); i += 1
                }
                guard i < chars.count else { throw YAMLError(line: line, message: "aspas não fechadas") }
                out.append(q)
                i += 1
                return out
            }
            while i < chars.count, !stopAt.contains(chars[i]) {
                out.append(chars[i]); i += 1
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
    }
}
