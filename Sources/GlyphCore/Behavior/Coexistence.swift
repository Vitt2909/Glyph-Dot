import Foundation

// Personalidade que aprende convivência (proposta 0002, ideia 6).
//
// Regras locais simples, sem chamada de IA: onde ele costuma ficar, quando
// brincar é bem-vindo, que brincadeiras você dispensa. Só muda a encenação.
// Este tipo não conhece ferramentas, política nem cérebro: não tem como mexer
// em permissão.

public struct Coexistence: Sendable, Codable, Equatable {
    /// Brincadeiras espontâneas ligadas (você pode desligar na casa/arquivo).
    public var spontaneous = true
    /// Peso de cada brincadeira espontânea (1 = normal). Dispensar reduz.
    public var weights: [String: Double] = [:]
    /// Dispensas seguidas de cada uma.
    public var dismissStreak: [String: Int] = [:]
    /// Desligada até (segundos desde 1970).
    public var mutedUntil: [String: Double] = [:]
    /// Quantas vezes você brincou em cada hora do dia (0…23).
    public var playfulHours: [Int] = Array(repeating: 0, count: 24)
    /// Onde você costuma soltá-lo: fração da largura da tela (0…1), as últimas.
    public var spots: [Double] = []

    public init() {}

    /// Dispensas seguidas que desligam uma brincadeira por uma semana.
    public static let muteAfter = 3
    public static let muteFor: TimeInterval = 7 * 86_400
    /// Brincadeiras que podem acontecer sem pedido (curtas, no lugar).
    public static let candidates: [FunCommand] = [.dance, .robot, .trick]
    public static let maxSpots = 20

    public func weight(_ c: FunCommand) -> Double { weights[c.rawValue] ?? 1 }

    public func isMuted(_ c: FunCommand, now: Date) -> Bool {
        (mutedUntil[c.rawValue] ?? 0) > now.timeIntervalSince1970
    }

    /// Você cortou a brincadeira (clique, "chega").
    public mutating func dismissed(_ c: FunCommand, now: Date) {
        let k = c.rawValue
        weights[k] = max(weight(c) * 0.5, 0.05)
        dismissStreak[k, default: 0] += 1
        if dismissStreak[k, default: 0] >= Self.muteAfter {
            mutedUntil[k] = now.addingTimeInterval(Self.muteFor).timeIntervalSince1970
            dismissStreak[k] = 0
        }
    }

    /// Deixou ir até o fim.
    public mutating func enjoyed(_ c: FunCommand) {
        weights[c.rawValue] = min(weight(c) * 1.25, 1)
        dismissStreak[c.rawValue] = 0
    }

    /// Você mesmo chamou para brincar nesta hora.
    public mutating func userPlayed(hour: Int) {
        guard (0..<24).contains(hour) else { return }
        if playfulHours.count != 24 { playfulHours = Array(repeating: 0, count: 24) }
        playfulHours[hour] += 1
    }

    public func isPlayfulHour(_ hour: Int) -> Bool {
        playfulHours.indices.contains(hour) && playfulHours[hour] > 0
    }

    /// Você o soltou aqui.
    public mutating func placed(fraction f: Double) {
        spots.append(f.clamped(0, 1))
        if spots.count > Self.maxSpots { spots.removeFirst(spots.count - Self.maxSpots) }
    }

    /// O lugar de sempre (mediana), com pelo menos 3 soltas.
    public var favoriteSpot: Double? {
        guard spots.count >= 3 else { return nil }
        let s = spots.sorted()
        return s[s.count / 2]
    }

    /// Pode brincar sem pedido agora? `building`: um build/teste está rodando.
    public func mayPlay(hour: Int, now: Date, userIdle: Double, building: Bool) -> Bool {
        guard spontaneous else { return false }
        guard building || isPlayfulHour(hour) else { return false }
        guard building || userIdle >= 20 else { return false }
        return Self.candidates.contains { !isMuted($0, now: now) && weight($0) > 0.05 }
    }

    /// Sorteia pelo peso, sem as desligadas. `u` em 0..<1.
    public func pick(u: Double, now: Date, available: (FunCommand) -> Bool = { _ in true }) -> FunCommand? {
        let pool = Self.candidates.filter { !isMuted($0, now: now) && available($0) }
        let total = pool.reduce(0) { $0 + weight($1) }
        guard total > 0 else { return nil }
        var r = u.clamped(0, 0.999_999) * total
        for c in pool {
            r -= weight(c)
            if r < 0 { return c }
        }
        return pool.last
    }
}

/// Apps de reunião e apresentação: o Glyph vai para casa.
public enum MeetingApps {
    public static let names: Set<String> = [
        "zoom.us", "Zoom", "Microsoft Teams", "Microsoft Teams (work or school)", "Webex", "Cisco Webex Meetings",
        "FaceTime", "Around", "Tuple", "Pop", "Discord",
    ]

    public static func contains(_ app: String?) -> Bool {
        guard let app else { return false }
        return names.contains(app)
    }
}

/// Comandos que são builds ou testes: enquanto rodam, ele pode explorar.
public enum BuildCommands {
    static let prefixes = [
        "swift build", "swift test", "xcodebuild", "make", "cmake --build", "ninja", "cargo build", "cargo test",
        "npm run build", "npm test", "npm run test", "yarn build", "yarn test", "pnpm build", "pnpm test",
        "go build", "go test", "gradle", "./gradlew", "mvn", "bazel", "pytest", "tox", "docker build",
    ]

    public static func isBuild(_ cmd: String) -> Bool {
        let c = cmd.trimmingCharacters(in: .whitespaces)
        return prefixes.contains { c == $0 || c.hasPrefix($0 + " ") } || FailureParser.looksLikeTestCommand(c)
    }
}
