import Foundation
import GlyphCore

/// A mala: o que o Glyph leva de um Mac para outro (M6, "viagem").
///
/// Vai na mala o que o usuário escreveu ou aprovou e não depende da máquina:
/// objetivos, habilidades aprovadas, memória, packs e a configuração (sem o
/// pareamento do corpo, que é por build). Fica em casa:
/// - a escada de confiança e as regras "sempre": confiança se ganha de novo
///   em cada máquina (pastas e repositórios são outros);
/// - o histórico, o diário e o quadro: são desta máquina;
/// - chaves de API: moram no Keychain e nunca saem dele;
/// - rascunhos de habilidade: ainda não foram aprovados.
///
/// Importar nunca sobrescreve: arquivo que já existe ganha uma cópia
/// `.da-mala` ao lado, para o usuário comparar.
public enum Mala {
    public static let format = "glyph-mala/1"
    public static let maxBytes = 20 << 20

    public struct Report: Sendable, Equatable {
        public var written: [String] = []
        public var conflicts: [String] = []
        public var skipped: [String] = []
    }

    struct Bundle: Codable {
        var formato: String
        var criado: Date
        var origem: String
        var arquivos: [String: String] // caminho relativo à casa → base64
    }

    /// O que vai na mala, relativo à casa.
    static let entries = ["goals.yaml", "config.yaml", "skills", "memoria", "packs"]

    static func included(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/").map(String.init)
        guard let first = parts.first, entries.contains(first) else { return false }
        if parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }) { return false }
        if first == "skills", parts.count > 1, parts[1] == "_rascunhos" { return false }
        return true
    }

    public static func export(casa: URL, to out: URL, origin: String = ProcessInfo.processInfo.hostName) throws -> [String] {
        var files: [String: String] = [:]
        var total = 0
        let fm = FileManager.default
        for entry in entries {
            let url = casa.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let rels: [String]
            if isDir.boolValue {
                let items = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])?.allObjects as? [URL] ?? []
                rels = items.compactMap { item in
                    let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard v?.isRegularFile == true, v?.isSymbolicLink != true else { return nil }
                    let full = item.standardizedFileURL.path
                    let base = casa.standardizedFileURL.path
                    guard full.hasPrefix(base + "/") else { return nil }
                    return String(full.dropFirst(base.count + 1))
                }
            } else {
                rels = [entry]
            }
            for rel in rels.sorted() where included(rel) {
                var data = try Data(contentsOf: casa.appendingPathComponent(rel))
                if rel == "config.yaml" { data = Data(stripPairing(String(decoding: data, as: UTF8.self)).utf8) }
                total += data.count
                guard total <= maxBytes else { throw ToolError.failed("mala maior que \(maxBytes >> 20) MB") }
                files[rel] = data.base64EncodedString()
            }
        }
        let bundle = Bundle(formato: format, criado: Date(), origem: origin, arquivos: files)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(bundle).write(to: out, options: .atomic)
        return files.keys.sorted()
    }

    /// Tira o pareamento do corpo (cdhash é por build, por máquina).
    static func stripPairing(_ yaml: String) -> String {
        yaml.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pareados:") {
                let indent = line.prefix { $0 == " " }
                return indent + "pareados: []"
            }
            return String(line)
        }.joined(separator: "\n")
    }

    public static func importBundle(_ file: URL, into casa: URL) throws -> Report {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attrs[.size] as? Int, size <= maxBytes * 2 else { throw ToolError.failed("mala grande demais") }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let bundle = try dec.decode(Bundle.self, from: Data(contentsOf: file))
        guard bundle.formato == format else { throw ToolError.failed("formato desconhecido: \(bundle.formato)") }
        var report = Report()
        let fm = FileManager.default
        for (rel, b64) in bundle.arquivos.sorted(by: { $0.key < $1.key }) {
            guard included(rel), let data = Data(base64Encoded: b64) else {
                report.skipped.append(rel)
                continue
            }
            if rel == "goals.yaml" {
                let (_, errors) = Goal.load(yaml: String(decoding: data, as: UTF8.self))
                if !errors.isEmpty {
                    report.skipped.append(rel + " (" + errors.joined(separator: "; ") + ")")
                    continue
                }
            }
            let dest = casa.appendingPathComponent(rel).standardizedFileURL
            guard dest.path.hasPrefix(casa.standardizedFileURL.path + "/") else {
                report.skipped.append(rel)
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                if (try? Data(contentsOf: dest)) == data { continue }
                try data.write(to: URL(fileURLWithPath: dest.path + ".da-mala"), options: .atomic)
                report.conflicts.append(rel)
            } else {
                try data.write(to: dest, options: .atomic)
                report.written.append(rel)
            }
        }
        return report
    }
}
