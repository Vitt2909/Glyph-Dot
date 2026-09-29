import XCTest
@testable import GlyphCore

final class CommunityPackTests: XCTestCase {
    var dir: URL!
    let repoPack = Packs.defaultPack

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ text: String, _ rel: String, in pack: URL) throws {
        let url = pack.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func manifest(_ id: String, licenca: String = "CC0-1.0") -> String {
        #"{"id":"\#(id)","nome":"Pack \#(id)","versao":"1.0.0","autor":"alguém","licenca":"\#(licenca)","formato":1}"#
    }

    func clipJSON(_ id: String, from base: String = "wave") throws -> String {
        let data = try Data(contentsOf: repoPack.appendingPathComponent("clips/\(base).json"))
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["id"] = id
        return String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    func testDefaultPackHasManifestAndLoadsClean() {
        let r = PackLoader.load(default: repoPack, community: [])
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.packs.map(\.id), ["default"])
        XCTAssertNotNil(r.clips["await"])
        XCTAssertNotNil(r.stickers["cartao"])
        // Os sinais protegidos existem no pack padrão.
        for id in PackLoader.protectedClips { XCTAssertNotNil(r.clips[id], id) }
        for id in PackLoader.protectedStickers { XCTAssertNotNil(r.stickers[id], id) }
    }

    func testCommunityPackAddsAndOverridesButNeverSafetySignals() throws {
        let p = dir.appendingPathComponent("festa")
        try write(manifest("festa"), "pack.json", in: p)
        try write(try clipJSON("danca"), "clips/danca.json", in: p)
        try write(try clipJSON("wave", from: "idle"), "clips/wave.json", in: p)
        try write(try clipJSON("await", from: "idle"), "clips/await.json", in: p)
        try write("echo oi", "clips/script.sh", in: p) // ignorado: pack é só dado
        let base = PackLoader.load(default: repoPack, community: [])
        let r = PackLoader.load(default: repoPack, community: [p])
        XCTAssertNotNil(r.clips["danca"])
        XCTAssertEqual(r.clips["wave"], try ClipLibrary.decode(Data(try clipJSON("wave", from: "idle").utf8)))
        XCTAssertEqual(r.clips["await"], base.clips["await"], "espera por aprovação é sinal de segurança")
        XCTAssertTrue(r.errors.contains { $0.contains("await") })
        XCTAssertEqual(r.packs.map(\.id), ["default", "festa"])
    }

    func testCommunityPackNeedsManifestWithLicense() throws {
        let semManifesto = dir.appendingPathComponent("a")
        try write(try clipJSON("x1"), "clips/x1.json", in: semManifesto)
        let semLicenca = dir.appendingPathComponent("b")
        try write(manifest("b", licenca: " "), "pack.json", in: semLicenca)
        try write(try clipJSON("x2"), "clips/x2.json", in: semLicenca)
        let formatoNovo = dir.appendingPathComponent("c")
        try write(#"{"id":"c","nome":"c","versao":"1","autor":"x","licenca":"MIT","formato":2}"#, "pack.json", in: formatoNovo)
        let r = PackLoader.load(default: repoPack, community: [semManifesto, semLicenca, formatoNovo])
        XCTAssertNil(r.clips["x1"])
        XCTAssertNil(r.clips["x2"])
        XCTAssertEqual(r.packs.map(\.id), ["default"])
        XCTAssertEqual(r.errors.count, 3)
    }

    func testOversizeAndMismatchedFilesAreRejected() throws {
        let p = dir.appendingPathComponent("grande")
        try write(manifest("grande"), "pack.json", in: p)
        try write(String(repeating: " ", count: PackLoader.maxFileBytes + 1), "clips/enorme.json", in: p)
        try write(try clipJSON("outro"), "clips/nome-errado.json", in: p)
        let r = PackLoader.loadPack(p, requireManifest: true)
        XCTAssertTrue(r.clips.clips.isEmpty)
        XCTAssertEqual(r.errors.count, 2)
    }

    func testDuplicatePackIDAndSymlinkedPacksAreSkipped() throws {
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try write(manifest("mesmo"), "pack.json", in: a)
        try write(manifest("mesmo"), "pack.json", in: b)
        let r = PackLoader.load(default: repoPack, community: [a, b])
        XCTAssertEqual(r.packs.map(\.id), ["default", "mesmo"])
        XCTAssertTrue(r.errors.contains { $0.contains("repetido") })

        let fora = FileManager.default.temporaryDirectory.appendingPathComponent("fora-\(UUID().uuidString.prefix(6))")
        try write(manifest("fora"), "pack.json", in: fora)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: fora)
        let found = PackLoader.communityPacks(in: dir).map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["a", "b"])
        try? FileManager.default.removeItem(at: fora)
    }
}
