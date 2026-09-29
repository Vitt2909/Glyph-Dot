import XCTest
@testable import GlyphCore
@testable import GlyphIPC

final class SocketTests: XCTestCase {
    func tempSocket() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("s.sock").path
    }

    func testRoundTripAndPeerUID() throws {
        let path = tempSocket()
        let server = UnixSocketServer(path: path)
        let got = expectation(description: "servidor recebe")
        let echoed = expectation(description: "cliente recebe resposta")
        let peerBox = Box<PeerCredentials?>(nil)
        server.onConnection = { conn in
            peerBox.value = conn.peer
            conn.onLine = { result in
                if case let .success(env) = result, case .hello = env.message {
                    got.fulfill()
                    conn.send(Envelope(id: "r1", message: .bubbleSay(BubbleSay(text: "oi"))))
                }
            }
            conn.start()
        }
        try server.start()
        defer { server.stop() }

        // Permissão 0600 no arquivo do socket.
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let client = try UnixSocketClient.connect(path: path)
        client.onLine = { result in
            if case let .success(env) = result, case let .bubbleSay(b) = env.message, b.text == "oi" { echoed.fulfill() }
        }
        client.start()
        client.send(Envelope(id: "h1", message: .hello(Hello(role: .body))))
        wait(for: [got, echoed], timeout: 5)
        XCTAssertEqual(peerBox.value?.uid, currentUID)
        client.close()
    }

    func testGarbageLineIsReportedNotFatal() throws {
        let path = tempSocket()
        let server = UnixSocketServer(path: path)
        let bad = expectation(description: "erro de framing")
        let good = expectation(description: "linha boa depois")
        server.onConnection = { conn in
            conn.onLine = { r in
                switch r {
                case .failure: bad.fulfill()
                case .success: good.fulfill()
                }
            }
            conn.start()
        }
        try server.start()
        defer { server.stop() }
        let client = try UnixSocketClient.connect(path: path)
        client.start()
        client.sendRaw(Data("isto não é json\n".utf8))
        client.send(Envelope(id: "h", message: .hello(Hello(role: .body))))
        wait(for: [bad, good], timeout: 5, enforceOrder: true)
    }

    func testVerifierRejectsOtherUsers() {
        let v = PeerVerifier()
        XCTAssertEqual(v.trust(nil), .rejected("credenciais do par ilegíveis"))
        XCTAssertEqual(v.trust(PeerCredentials(uid: currentUID &+ 1)), .rejected("par de outro usuário (uid \(currentUID &+ 1))"))
        // Mesmo usuário sem assinatura: corpo não verificado, não pode aprovar.
        let same = v.trust(PeerCredentials(uid: currentUID))
        XCTAssertEqual(same, .unverifiedBody)
        XCTAssertFalse(same.canApprove)
    }

    func testRequirementText() {
        XCTAssertEqual(PeerVerifier().requirement, #"identifier "dev.glyph.Glyph""#)
        XCTAssertTrue(PeerVerifier(teamID: "ABCDE12345").requirement.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
