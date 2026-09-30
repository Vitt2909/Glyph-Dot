import XCTest
@testable import GlyphCore

final class ProjectMarkerTests: XCTestCase {
    let d = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 18, minute: 40))!

    func testRoundTripAndYourNotesSurvive() {
        var m = ProjectMarker(name: "vk", root: "/u/dev/vk")
        m.set(.branch, "`fix/reconexao`", origin: "git", date: d)
        m.set(.failing, "ReconnectTests.swift:88", origin: "autonomia", date: d)
        m.addNote("falta verificar o timeout", date: d)
        let text = m.render()
        XCTAssertTrue(text.contains("- ramo: `fix/reconexao` · git · 2026-09-29 18:40"))
        XCTAssertEqual(ProjectMarker.parse(text), m)

        var again = ProjectMarker.parse(text)!
        again.set(.note, nil, origin: "git", date: d) // automático nunca apaga nota
        XCTAssertEqual(again.facts.filter { $0.kind == .note }.count, 1)
        again.set(.branch, "`main`", origin: "git", date: d)
        XCTAssertEqual(again.facts.filter { $0.kind == .branch }.map(\.text), ["`main`"])
    }

    func testResumeLinePrefersYourNoteThenFailingTest() {
        var m = ProjectMarker(name: "vk", root: "/r")
        XCTAssertNil(m.resumeLine)
        m.set(.branch, "main", origin: "git", date: d)
        XCTAssertNil(m.resumeLine, "na main e sem nada: silêncio")
        m.set(.changes, "Reconnect.swift", origin: "git", date: d)
        XCTAssertEqual(m.resumeLine, "vk: mexendo em Reconnect.swift")
        m.set(.failing, "ReconnectTests.swift:88", origin: "autonomia", date: d)
        XCTAssertEqual(m.resumeLine, "vk: falta ReconnectTests.swift:88")
        m.addNote("verificar o timeout", date: d)
        XCTAssertEqual(m.resumeLine, "vk: verificar o timeout")
    }

    func testHandEditedFileParses() {
        let text = """
        # site

        pasta: /u/site

        - nota: trocar o logo · você · 2026-09-01 10:00
        - linha estranha sem formato
        - ramo: `dev` · git · 2026-09-01 10:00
        """
        let m = ProjectMarker.parse(text)!
        XCTAssertEqual(m.facts.map(\.kind), [.note, .branch])
        XCTAssertEqual(m.resumeLine, "site: trocar o logo")
    }

    func testFactsAreOneLineAndCannotBreakTheFormat() {
        var m = ProjectMarker(name: "x", root: "/x")
        m.addNote("uma\nduas · três", date: d)
        XCTAssertEqual(m.facts[0].text, "uma duas - três")
        XCTAssertEqual(ProjectMarker.parse(m.render())?.facts, m.facts)
    }
}
