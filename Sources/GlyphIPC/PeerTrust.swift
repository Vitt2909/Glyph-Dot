import Foundation
#if canImport(Security)
import Security
#endif

/// O que o `glyphd` concede a quem conectou no socket.
public enum PeerTrust: Sendable, Equatable {
    /// Outro usuário, ou credenciais ilegíveis: a conexão é fechada.
    case rejected(String)
    /// Mesmo usuário, mas sem assinatura confirmada: pode mandar `world.*` e
    /// `input.*`, **nunca** `approval.response`.
    case unverifiedBody
    /// O `Glyph.app` assinado: pode aprovar.
    case verifiedBody

    public var canApprove: Bool { self == .verifiedBody }
}

/// Decide a confiança num par. O papel nunca vem do conteúdo da mensagem.
public struct PeerVerifier: Sendable {
    /// Identificador de assinatura do app.
    public var bundleIdentifier: String
    /// Equipe Developer ID. Com ela, a exigência é "assinado pela Apple para esta equipe".
    public var teamID: String?
    /// cdhashes pareados com `glyphd pair` (para builds sem Developer ID).
    public var pairedCDHashes: Set<String>

    public init(bundleIdentifier: String = "dev.glyph.Glyph", teamID: String? = nil, pairedCDHashes: Set<String> = []) {
        self.bundleIdentifier = bundleIdentifier
        self.teamID = teamID
        self.pairedCDHashes = pairedCDHashes
    }

    public func trust(_ peer: PeerCredentials?, expectedUID: UInt32 = currentUID) -> PeerTrust {
        guard let peer else { return .rejected("credenciais do par ilegíveis") }
        guard peer.uid == expectedUID else { return .rejected("par de outro usuário (uid \(peer.uid))") }
        #if canImport(Security)
        if let token = peer.auditToken, CodeSignature.matches(auditToken: token, verifier: self) {
            return .verifiedBody
        }
        #endif
        return .unverifiedBody
    }

    /// Texto da exigência de assinatura (sintaxe de `csreq`).
    public var requirement: String {
        if let teamID, !teamID.isEmpty {
            return #"identifier "\#(bundleIdentifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(teamID)""#
        }
        return #"identifier "\#(bundleIdentifier)""#
    }
}

#if canImport(Security)
/// Verificação de assinatura via audit token (macOS).
public enum CodeSignature {
    static func matches(auditToken: [UInt8], verifier: PeerVerifier) -> Bool {
        let attrs = [kSecGuestAttributeAudit: Data(auditToken)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(verifier.requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        guard SecCodeCheckValidity(code, [], req) == errSecSuccess else { return false }
        // Com Developer ID a exigência já basta. Sem ela, só vale o cdhash pareado.
        if let team = verifier.teamID, !team.isEmpty { return true }
        guard let hash = cdhash(of: code) else { return false }
        return verifier.pairedCDHashes.contains(hash)
    }

    static func cdhash(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return cdhash(ofStatic: staticCode)
    }

    static func cdhash(ofStatic code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// cdhash de um app no disco (para `glyphd pair`).
    public static func cdhash(ofAppAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return cdhash(ofStatic: code)
    }
}
#endif
