import Foundation

/// Curva de uma chave até a próxima.
public enum Ease: String, Sendable, Codable {
    case linear
    case `in`
    case out
    case inOut
    /// Segura o valor até a próxima chave.
    case step

    public func apply(_ t: Double) -> Double {
        let t = t.clamped(0, 1)
        switch self {
        case .linear: return t
        case .in: return t * t
        case .out: return 1 - (1 - t) * (1 - t)
        case .inOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .step: return 0
        }
    }
}

public struct ClipKey: Sendable, Equatable, Codable {
    public var t: Double
    public var ease: Ease?
    public var pose: [String: Double]

    public init(t: Double, ease: Ease? = nil, pose: [String: Double]) {
        self.t = t
        self.ease = ease
        self.pose = pose
    }
}

public struct ClipDot: Sendable, Equatable, Codable {
    public var mode: DotMode
    public var speed: Double?

    public init(mode: DotMode, speed: Double? = nil) {
        self.mode = mode
        self.speed = speed
    }
}

/// Um clipe de animação (formato em docs/ANIMATION.md).
public struct Clip: Sendable, Equatable, Codable {
    public var id: String
    public var fps: Double?
    public var loop: Bool?
    public var keys: [ClipKey]
    public var dot: ClipDot?

    public init(id: String, fps: Double? = nil, loop: Bool? = nil, keys: [ClipKey], dot: ClipDot? = nil) {
        self.id = id
        self.fps = fps
        self.loop = loop
        self.keys = keys
        self.dot = dot
    }

    public var framesPerSecond: Double { fps ?? StickerStyle.default.poseFPS }
    public var loops: Bool { loop ?? false }

    /// Duração de uma volta. Em loop, inclui o trecho da última chave de volta à primeira.
    public var duration: Double {
        guard let last = keys.last else { return 0 }
        if loops, keys.count > 1 { return last.t + (keys[1].t - keys[0].t) }
        return last.t
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case badID(String)
        case noKeys(String)
        case unorderedKeys(String)
        case badFPS(String)
        case unknownChannel(clip: String, channel: String)

        public var description: String {
            switch self {
            case let .badID(id): return "id inválido: \(id)"
            case let .noKeys(id): return "\(id): clipe sem chaves"
            case let .unorderedKeys(id): return "\(id): chaves fora de ordem"
            case let .badFPS(id): return "\(id): fps fora de 1…60"
            case let .unknownChannel(id, ch): return "\(id): canal desconhecido \(ch)"
            }
        }
    }

    public static let knownChannels: Set<String> =
        Set(Joint.allCases.map(\.rawValue)).union(PoseChannel.allCases.map(\.rawValue))

    public func validate() throws {
        guard !id.isEmpty, id.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }), id.allSatisfy(\.isASCII) else {
            throw ValidationError.badID(id)
        }
        guard !keys.isEmpty else { throw ValidationError.noKeys(id) }
        guard zip(keys, keys.dropFirst()).allSatisfy({ $0.t < $1.t }), keys[0].t >= 0 else {
            throw ValidationError.unorderedKeys(id)
        }
        guard (1...60).contains(framesPerSecond) else { throw ValidationError.badFPS(id) }
        for k in keys {
            for ch in k.pose.keys where !Self.knownChannels.contains(ch) {
                throw ValidationError.unknownChannel(clip: id, channel: ch)
            }
        }
    }

    /// Pose no tempo `t` (segundos desde o início), amostrada em `fps`:
    /// é isso que dá o ar de desenho animado "em dois".
    public func sample(at t: Double, quantize: Bool = true) -> Pose {
        guard let first = keys.first else { return .rest }
        guard keys.count > 1 else { return Pose.rest.merging(Pose(first.pose)) }
        var time = max(t, 0)
        if quantize {
            let f = framesPerSecond
            time = (time * f + 1e-9).rounded(.down) / f
        }
        if loops {
            let d = duration
            if d > 0 { time = time.truncatingRemainder(dividingBy: d) }
        } else if time >= keys.last!.t {
            return Pose.rest.merging(Pose(keys.last!.pose))
        }

        // Chave anterior e próxima (em loop, a última volta para a primeira).
        var a = keys[0], b = keys[1], span = keys[1].t - keys[0].t, local = time - keys[0].t
        if let i = keys.lastIndex(where: { $0.t <= time }) {
            a = keys[i]
            if i + 1 < keys.count {
                b = keys[i + 1]
                span = b.t - a.t
            } else {
                b = keys[0]
                span = duration - a.t
            }
            local = time - a.t
        }
        let u = (a.ease ?? .linear).apply(span > 0 ? local / span : 1)
        return Pose.lerp(Pose.rest.merging(Pose(a.pose)), Pose.rest.merging(Pose(b.pose)), u)
    }
}

/// Os clipes disponíveis, por id.
public struct ClipLibrary: Sendable {
    public private(set) var clips: [String: Clip] = [:]

    public init(_ clips: [Clip] = []) {
        for c in clips { self.clips[c.id] = c }
    }

    public subscript(id: String) -> Clip? { clips[id] }

    public mutating func add(_ clip: Clip) { clips[clip.id] = clip }

    public static func decode(_ data: Data) throws -> Clip {
        let clip = try JSONDecoder().decode(Clip.self, from: data)
        try clip.validate()
        return clip
    }

    /// Carrega todos os `.json` de `clips/` dentro de um pack. Clipes inválidos
    /// são reportados em `errors` e ignorados.
    public static func load(pack: URL) -> (library: ClipLibrary, errors: [String]) {
        let dir = pack.appendingPathComponent("clips", isDirectory: true)
        var lib = ClipLibrary()
        var errors: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            do {
                let clip = try decode(Data(contentsOf: url))
                if clip.id != url.deletingPathExtension().lastPathComponent {
                    errors.append("\(url.lastPathComponent): id \(clip.id) diferente do nome do arquivo")
                    continue
                }
                lib.add(clip)
            } catch {
                errors.append("\(url.lastPathComponent): \(error)")
            }
        }
        return (lib, errors)
    }
}
