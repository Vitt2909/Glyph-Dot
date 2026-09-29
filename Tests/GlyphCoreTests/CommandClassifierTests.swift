import XCTest
@testable import GlyphCore

final class CommandClassifierTests: XCTestCase {
    func c(_ s: String) -> ActionClass { CommandClassifier.classify(s).actionClass }

    func testReadOnly() {
        for cmd in ["ls -la", "git status", "git log --oneline -5", "cat README.md | head -3", "rg TODO Sources",
                    "git diff HEAD~1", "pwd", "echo oi 2>/dev/null", "ls >&2", "git branch", "find . -name '*.swift'"] {
            XCTAssertEqual(c(cmd), .read, cmd)
        }
    }

    func testCompute() {
        for cmd in ["swift test", "swift build -c release", "npm test", "npm run test", "cargo test", "go test ./...",
                    "make", "make test", "pytest -q", "python3 -m pytest", "xcodebuild -scheme X test"] {
            XCTAssertEqual(c(cmd), .compute, cmd)
        }
    }

    func testLocalWrite() {
        for cmd in ["git add -A", "git commit -m 'x'", "mkdir -p build", "echo oi > nota.txt", "sed -i '' s/a/b/ f",
                    "git checkout -b glyph/fix", "npm install", "git worktree add ../w glyph/x", "curl -o f https://x"] {
            XCTAssertEqual(c(cmd), .localWrite, cmd)
        }
    }

    func testNetwork() {
        XCTAssertEqual(c("curl -s https://api.github.com"), .networkRead)
        XCTAssertEqual(c("git fetch origin"), .networkRead)
        XCTAssertEqual(c("curl -X POST -d a=1 https://x"), .externalEffect)
        XCTAssertEqual(c("curl -X GET https://x"), .networkRead)
        XCTAssertEqual(c("gh pr view 3"), .networkRead)
        XCTAssertEqual(c("gh pr create --draft"), .externalEffect)
    }

    func testIrreversible() {
        XCTAssertEqual(c("git push origin glyph/fix-tests"), .externalEffect)
        XCTAssertEqual(c("git push origin main"), .destructive, "push na main")
        XCTAssertEqual(c("git push -f origin glyph/x"), .destructive, "push forçado")
        XCTAssertEqual(c("git push --force-with-lease"), .destructive)
        XCTAssertEqual(c("rm -rf build"), .destructive)
        XCTAssertEqual(c("git reset --hard HEAD"), .destructive)
        XCTAssertEqual(c("git clean -fdx"), .destructive)
        XCTAssertEqual(c("find . -name x -delete"), .destructive)
        XCTAssertEqual(c("npm publish"), .externalEffect)
    }

    func testCompositeTakesWorst() {
        XCTAssertEqual(c("swift test && git push origin main"), .destructive)
        XCTAssertEqual(c("ls; rm x"), .destructive)
        XCTAssertEqual(c("git status | tee out.txt"), .localWrite)
        XCTAssertEqual(c("echo 'a; rm -rf /' "), .read, "separador dentro de aspas não conta")
    }

    func testForbiddenAndOpaque() {
        let s = CommandClassifier.classify("sudo rm -rf /")
        XCTAssertTrue(s.forbidden)
        XCTAssertTrue(CommandClassifier.classify("ls && sudo reboot").forbidden)
        XCTAssertEqual(c("echo $(cat ~/.ssh/id_rsa)"), .externalEffect)
        XCTAssertEqual(c("bash -c 'ls'"), .externalEffect)
        XCTAssertEqual(c("frobnicate --now"), .externalEffect, "desconhecido é conservador")
        XCTAssertEqual(c("FOO=1 swift test"), .compute, "atribuição na frente")
        XCTAssertEqual(c("/usr/bin/git status"), .read, "caminho absoluto")
        XCTAssertEqual(c("./test"), .externalEffect, "script local não é o builtin test")
        XCTAssertEqual(c("~/bin/deploy.sh"), .externalEffect)
    }
}
