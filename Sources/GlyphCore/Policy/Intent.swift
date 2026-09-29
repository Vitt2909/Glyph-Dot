import Foundation

/// Tudo que o Glyph percebe vira uma intenção.
public struct Intent: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var source: String
    /// "2 testes falharam em vk/"
    public var summary: String
    /// Casa com algum objetivo? 0…1
    public var relevance: Double
    /// Confiança no plano (antes da calibração). 0…1
    public var confidence: Double
    public var urgency: Double
    /// Custo de interromper, por tipo de intenção. 0…1
    public var interruptCost: Double
    public var actionClass: ActionClass
    public var scope: String
    /// `false` se nasceu de conteúdo observado.
    public var trusted: Bool
    /// Objetivo que a originou (M4).
    public var goalID: String?

    public init(id: UUID = UUID(), source: String, summary: String, relevance: Double, confidence: Double,
                urgency: Double, interruptCost: Double = 0.5, actionClass: ActionClass, scope: String,
                trusted: Bool = true, goalID: String? = nil) {
        self.id = id
        self.source = source
        self.summary = summary
        self.relevance = relevance
        self.confidence = confidence
        self.urgency = urgency
        self.interruptCost = interruptCost
        self.actionClass = actionClass
        self.scope = scope
        self.trusted = trusted
        self.goalID = goalID
    }
}

/// O que fazer com uma intenção, pela pontuação.
public enum IntentVerdict: String, Sendable, Equatable, Codable {
    /// S < 0,3: descarta e registra.
    case discard
    /// 0,3 ≤ S < 0,6: anota no quadro ou só aponta.
    case note
    /// S ≥ 0,6: age de acordo com o nível de confiança da classe.
    case act
}

/// Foco do usuário (`F`): quanto custa interromper agora.
public enum FocusEstimator {
    public static func focus(_ f: UserFocus, typingRecently: Bool) -> Double {
        switch f {
        case .fullscreen, .meeting: return 1
        case .typing: return 0.8
        case .normal: return typingRecently ? 0.6 : 0.2
        }
    }
}

/// Calibração da confiança pelo histórico: se o cérebro diz 0,9 e acerta 60%
/// das vezes naquela classe, o valor efetivo cai.
public struct ConfidenceCalibrator: Sendable, Codable, Equatable {
    public struct Stats: Sendable, Codable, Equatable {
        public var predicted: Double = 0
        public var succeeded: Double = 0
        public var count: Int = 0
    }

    public private(set) var stats: [ActionClass: Stats] = [:]
    /// Com poucos dados, confia no valor declarado.
    public static let minSamples = 5

    public init() {}

    public mutating func record(_ c: ActionClass, predicted: Double, success: Bool) {
        var s = stats[c] ?? Stats()
        s.predicted += predicted.clamped(0, 1)
        s.succeeded += success ? 1 : 0
        s.count += 1
        stats[c] = s
    }

    public func calibrated(_ c: ActionClass, _ confidence: Double) -> Double {
        guard let s = stats[c], s.count >= Self.minSamples, s.predicted > 0 else { return confidence.clamped(0, 1) }
        let rate = s.succeeded / Double(s.count)
        let meanPredicted = s.predicted / Double(s.count)
        return (confidence * min(1, rate / meanPredicted)).clamped(0, 1)
    }
}

/// S = R · C · U · (1 − I · F)
public enum IntentScorer {
    public static func score(_ i: Intent, focus: Double, calibrator: ConfidenceCalibrator = ConfidenceCalibrator()) -> Double {
        let r = i.relevance.clamped(0, 1)
        let c = calibrator.calibrated(i.actionClass, i.confidence)
        let u = i.urgency.clamped(0, 1)
        let penalty = i.interruptCost.clamped(0, 1) * focus.clamped(0, 1)
        return r * c * u * (1 - penalty)
    }

    /// A reversibilidade não entra na conta: é a trava separada da `Policy`.
    public static func verdict(_ s: Double) -> IntentVerdict {
        s < 0.3 ? .discard : (s < 0.6 ? .note : .act)
    }
}
