import Foundation

/// O manifesto de um pack (`pack.json`).
///
/// Pack é só dado: clipes e stickers em JSON. Nada de código, nada de script,
/// nada de rede. O carregador ignora qualquer outro arquivo.
public struct PackManifest: Sendable, Equatable, Codable {
    public var id: String
    public var nome: String
    public var versao: String
    public var autor: String
    /// Licença dos assets (ex.: "CC-BY-4.0"). Obrigatória em pack da comunidade.
    public var licenca: String
    public var descricao: String?
    /// Versão do formato de pack. Hoje só existe a 1.
    public var formato: Int

    public init(id: String, nome: String, versao: String, autor: String, licenca: String, descricao: String? = nil, formato: Int = 1) {
        self.id = id
        self.nome = nome
        self.versao = versao
        self.autor = autor
        self.licenca = licenca
        self.descricao = descricao
        self.formato = formato
    }

    public func validate() throws {
        guard !id.isEmpty, id.count <= 64,
              id.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }) else {
            throw PackError.invalid("id de pack inválido: \(id)")
        }
        guard formato == 1 else { throw PackError.invalid("\(id): formato \(formato) desconhecido (este Glyph lê o 1)") }
        guard !licenca.trimmingCharacters(in: .whitespaces).isEmpty else { throw PackError.invalid("\(id): falta a licença") }
        guard !nome.isEmpty, nome.count <= 80, autor.count <= 120 else { throw PackError.invalid("\(id): nome ou autor inválido") }
    }
}

public enum PackError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case let .invalid(m): return m }
    }
}

/// Um pack carregado.
public struct Pack: Sendable {
    public var manifest: PackManifest?
    public var clips: ClipLibrary
    public var stickers: [String: Sticker]
    /// Cenas ligadas a eventos reais (`scenes/*.json`).
    public var scenes: [Scene] = []
    public var errors: [String]
}

/// Carrega o pack padrão e os da comunidade, com os da comunidade por cima.
///
/// Regras (docs/PACKS.md):
/// - só `clips/*.json` e `stickers/*.json` são lidos, com limite de tamanho;
/// - pack da comunidade precisa de `pack.json` válido, com licença;
/// - os sinais de segurança não podem ser trocados: o clipe de espera por
///   aprovação, o de erro e o de alerta, e os stickers do cartão, do freio e
///   do escudo do Auditor. Quem vê o Glyph pedindo permissão precisa
///   reconhecer o pedido, qualquer que seja o pack.
public enum PackLoader {
    public static let protectedClips: Set<String> = ["await", "error", "alert"]
    public static let protectedStickers: Set<String> = ["cartao", "pausa", "escudo"]
    public static let maxFileBytes = 256 * 1024
    public static let maxFilesPerKind = 200

    public static func load(default defaultPack: URL, community: [URL]) -> (clips: ClipLibrary, stickers: [String: Sticker], packs: [PackManifest], errors: [String]) {
        let base = loadPack(defaultPack, requireManifest: false)
        var clips = base.clips
        var stickers = base.stickers
        var manifests = base.manifest.map { [$0] } ?? []
        var errors = base.errors
        var seen = Set(manifests.map(\.id))
        for url in community.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let p = loadPack(url, requireManifest: true)
            errors += p.errors
            guard let m = p.manifest else { continue }
            guard !seen.contains(m.id) else {
                errors.append("\(m.id): pack repetido, ignorado")
                continue
            }
            seen.insert(m.id)
            manifests.append(m)
            for (id, clip) in p.clips.clips.sorted(by: { $0.key < $1.key }) {
                if protectedClips.contains(id) {
                    errors.append("\(m.id): o clipe \(id) é sinal de segurança e não pode ser trocado")
                    continue
                }
                clips.add(clip)
            }
            for (id, s) in p.stickers.sorted(by: { $0.key < $1.key }) {
                if protectedStickers.contains(id) {
                    errors.append("\(m.id): o sticker \(id) é sinal de segurança e não pode ser trocado")
                    continue
                }
                stickers[id] = s
            }
        }
        return (clips, stickers, manifests, errors)
    }

    /// Cenas de todos os packs, uma por evento: a da comunidade vence a padrão.
    public static func scenes(default defaultPack: URL, community: [URL]) -> [SceneEvent: Scene] {
        var out: [SceneEvent: Scene] = [:]
        for s in loadPack(defaultPack, requireManifest: false).scenes { out[s.event] = s }
        for url in community.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for s in loadPack(url, requireManifest: true).scenes { out[s.event] = s }
        }
        return out
    }

    /// As pastas de pack dentro de `dir` (cada subpasta é um pack).
    public static func communityPacks(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return items.filter { url in
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Link simbólico não vale: o pack precisa morar dentro da casa.
            return v?.isDirectory == true && v?.isSymbolicLink != true && !url.lastPathComponent.hasPrefix(".")
        }
    }

    public static func loadPack(_ dir: URL, requireManifest: Bool) -> Pack {
        var errors: [String] = []
        let name = dir.lastPathComponent
        var manifest: PackManifest?
        let manifestURL = dir.appendingPathComponent("pack.json")
        if let data = readLimited(manifestURL) {
            do {
                let m = try JSONDecoder().decode(PackManifest.self, from: data)
                try m.validate()
                manifest = m
            } catch {
                errors.append("\(name)/pack.json: \(error)")
            }
        } else if requireManifest {
            errors.append("\(name): falta pack.json")
        }
        if requireManifest && manifest == nil {
            return Pack(manifest: nil, clips: ClipLibrary(), stickers: [:], scenes: [], errors: errors)
        }
        let prefix = manifest?.id ?? name
        var clips = ClipLibrary()
        for (file, data) in jsonFiles(dir.appendingPathComponent("clips"), errors: &errors, pack: prefix) {
            do {
                let clip = try ClipLibrary.decode(data)
                guard clip.id == file else {
                    errors.append("\(prefix)/clips/\(file).json: id \(clip.id) diferente do nome do arquivo")
                    continue
                }
                clips.add(clip)
            } catch {
                errors.append("\(prefix)/clips/\(file).json: \(error)")
            }
        }
        var stickers: [String: Sticker] = [:]
        for (file, data) in jsonFiles(dir.appendingPathComponent("stickers"), errors: &errors, pack: prefix) {
            do {
                let s = try JSONDecoder().decode(Sticker.self, from: data)
                try s.validate()
                guard s.id == file else {
                    errors.append("\(prefix)/stickers/\(file).json: id diferente do nome do arquivo")
                    continue
                }
                stickers[s.id] = s
            } catch {
                errors.append("\(prefix)/stickers/\(file).json: \(error)")
            }
        }
        var scenes: [Scene] = []
        for (file, data) in jsonFiles(dir.appendingPathComponent("scenes"), errors: &errors, pack: prefix) {
            do {
                let s = try Scene.decode(data)
                guard s.id == file else {
                    errors.append("\(prefix)/scenes/\(file).json: id diferente do nome do arquivo")
                    continue
                }
                scenes.append(s)
            } catch {
                errors.append("\(prefix)/scenes/\(file).json: \(error)")
            }
        }
        return Pack(manifest: manifest, clips: clips, stickers: stickers, scenes: scenes, errors: errors)
    }

    private static func jsonFiles(_ dir: URL, errors: inout [String], pack: String) -> [(String, Data)] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.count > maxFilesPerKind {
            errors.append("\(pack)/\(dir.lastPathComponent): mais de \(maxFilesPerKind) arquivos; o resto foi ignorado")
        }
        var out: [(String, Data)] = []
        for url in files.prefix(maxFilesPerKind) {
            guard let data = readLimited(url) else {
                errors.append("\(pack)/\(dir.lastPathComponent)/\(url.lastPathComponent): ilegível ou maior que \(maxFileBytes / 1024) KB")
                continue
            }
            out.append((url.deletingPathExtension().lastPathComponent, data))
        }
        return out
    }

    private static func readLimited(_ url: URL) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= maxFileBytes else { return nil }
        return try? Data(contentsOf: url)
    }
}
