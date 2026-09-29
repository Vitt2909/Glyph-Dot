import XCTest
@testable import GlyphCore

final class MiniYAMLTests: XCTestCase {
    let goals = """
    # casa/goals.yaml
    - id: testes-verdes
      descricao: "Manter os testes do repositório VK passando"
      escopo: ~/dev/vk
      gatilhos: [git.commit, shell.exit_nonzero]
      sucesso: "swift test"          # código de saída 0
      classes_permitidas: [read, compute, local_write]
      orcamento_diario: { acoes: 40, tokens: 300000, usd: 1.50 }
      horario: "sempre"

    - id: resumo-manha
      descricao: "Deixar um diário do que aconteceu durante a noite"
      horario: "07:30"
      classes_permitidas: [read]
    """

    func testPlanGoalsFile() throws {
        let v = try MiniYAML.parse(goals)
        guard case let .array(items) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["id"], .string("testes-verdes"))
        XCTAssertEqual(items[0]["escopo"], .string("~/dev/vk"))
        XCTAssertEqual(items[0]["gatilhos"], .array([.string("git.commit"), .string("shell.exit_nonzero")]))
        XCTAssertEqual(items[0]["sucesso"], .string("swift test"), "comentário depois do valor some")
        XCTAssertEqual(items[0]["orcamento_diario"]?["usd"], .double(1.5))
        XCTAssertEqual(items[0]["orcamento_diario"]?["tokens"], .int(300000))
        XCTAssertEqual(items[1]["horario"], .string("07:30"), "hora não vira chave")
    }

    func testNestedMapsAndListsAtKeyIndent() throws {
        let v = try MiniYAML.parse("""
        brain:
          provider: anthropic
          model: claude-opus-5-5
        tools:
        - shell
        - web.search
        shell:
          allowed:
            - ~/dev
            - /tmp
          timeout: 30
        empty:
        flag: yes
        """)
        XCTAssertEqual(v["brain"]?["model"], .string("claude-opus-5-5"))
        XCTAssertEqual(v["tools"], .array([.string("shell"), .string("web.search")]))
        XCTAssertEqual(v["shell"]?["allowed"], .array([.string("~/dev"), .string("/tmp")]))
        XCTAssertEqual(v["empty"], .null)
        XCTAssertEqual(v["flag"], .bool(true))
    }

    func testQuotesAndHashes() throws {
        let v = try MiniYAML.parse("""
        a: "texto # não é comentário"
        b: 'it''s'
        c: cor#azul
        "chave com: dois pontos": 1
        d: "linha\\nnova"
        """)
        XCTAssertEqual(v["a"], .string("texto # não é comentário"))
        XCTAssertEqual(v["b"], .string("it's"))
        XCTAssertEqual(v["c"], .string("cor#azul"))
        XCTAssertEqual(v["chave com: dois pontos"], .int(1))
        XCTAssertEqual(v["d"], .string("linha\nnova"))
    }

    func testBlockScalars() throws {
        let v = try MiniYAML.parse("""
        prompt: |
          linha um
            recuada
          linha três
        dobrado: >-
          a
          b
        fim: ok
        """)
        XCTAssertEqual(v["prompt"], .string("linha um\n  recuada\nlinha três\n"))
        XCTAssertEqual(v["dobrado"], .string("a b"))
        XCTAssertEqual(v["fim"], .string("ok"))
    }

    func testListOfMapsWithNestedList() throws {
        let v = try MiniYAML.parse("""
        rules:
          - action: git.push
            targets:
              - origin/glyph/*
            expires: "2026-10-13T00:00:00Z"
          - action: shell
        """)
        guard case let .array(r)? = v["rules"] else { return XCTFail() }
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0]["targets"], .array([.string("origin/glyph/*")]))
        XCTAssertEqual(r[1]["action"], .string("shell"))
    }

    func testErrors() {
        XCTAssertThrowsError(try MiniYAML.parse("a: 1\na: 2"))
        XCTAssertThrowsError(try MiniYAML.parse("a: [1, 2"))
        XCTAssertThrowsError(try MiniYAML.parse("a: &anc 1\nb: *anc".replacingOccurrences(of: "a: &anc 1", with: "&anc a: 1")))
        XCTAssertThrowsError(try MiniYAML.parse("a:\n\tb: 1"))
        XCTAssertThrowsError(try MiniYAML.parse("a: 1\n   b: 2"))
    }

    func testDecodable() throws {
        struct Cfg: Decodable, Equatable { var name: String; var n: Int; var tags: [String] }
        let c = try MiniYAML.decode(Cfg.self, from: "name: glyph\nn: 3\ntags: [a, b]\n")
        XCTAssertEqual(c, Cfg(name: "glyph", n: 3, tags: ["a", "b"]))
    }

    func testEmptyDocument() throws {
        XCTAssertEqual(try MiniYAML.parse("# nada\n\n"), .null)
    }
}
