import Foundation

/// Acha, na saída de uma bateria de testes, onde está a primeira falha.
/// Cobre XCTest/Swift Testing, pytest, Jest/Vitest, Go e Rust; senão, o
/// primeiro "arquivo:linha" perto de uma palavra de falha.
public enum FailureParser {
    public struct Failure: Sendable, Equatable {
        public var file: String
        public var line: Int?
        /// Quantas falhas a saída menciona (estimativa).
        public var count: Int

        public init(file: String, line: Int?, count: Int) {
            self.file = file
            self.line = line
            self.count = count
        }

        /// "FooTests.swift:42" — curto o bastante para a bolha.
        public var short: String {
            let name = (file as NSString).lastPathComponent
            return line.map { "\(name):\($0)" } ?? name
        }
    }

    static let patterns: [(String, Bool)] = [
        (#"([\w./+-]+\.swift):(\d+):(?:\d+:)? error"#, true),
        (#"recorded an issue at ([\w./+-]+\.swift):(\d+)"#, true),
        (#"FAILED ([\w./+-]+\.py)(?:::[\w\[\]-]+)?"#, false),
        (#"([\w./+-]+\.py):(\d+): (?:\w+Error|AssertionError|assert)"#, true),
        (#"\(([\w./+-]+\.(?:js|jsx|ts|tsx|mjs|cjs)):(\d+):\d+\)"#, true),
        (#"([\w./+-]+_test\.go):(\d+):"#, true),
        (#"panicked at ([\w./+-]+\.rs):(\d+)"#, true),
        (#"--> ([\w./+-]+\.rs):(\d+)"#, true),
    ]

    public static func first(in output: String) -> Failure? {
        let count = countFailures(output)
        for (p, hasLine) in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let fr = Range(m.range(at: 1), in: output) else { continue }
            var line: Int?
            if hasLine, m.numberOfRanges > 2, let lr = Range(m.range(at: 2), in: output) { line = Int(output[lr]) }
            return Failure(file: String(output[fr]), line: line, count: max(count, 1))
        }
        // Genérico: "arquivo.ext:linha" numa linha que fala de falha/erro.
        for l in output.split(separator: "\n") where l.range(of: "(?i)fail|error|erro", options: .regularExpression) != nil {
            if let r = l.range(of: #"[\w./+-]+\.[a-z]{1,5}:\d+"#, options: .regularExpression) {
                let parts = l[r].split(separator: ":")
                return Failure(file: String(parts[0]), line: Int(parts[1]), count: max(count, 1))
            }
        }
        return nil
    }

    public static func countFailures(_ output: String) -> Int {
        let patterns = [#"(?m): error: "#, #"(?m)^FAILED "#, #"(?m)^--- FAIL"#, #"(?m)^\s*● "#, #"(?m)recorded an issue"#, #"(?m)panicked at"#]
        var best = 0
        for p in patterns {
            let n = (try? NSRegularExpression(pattern: p))?.numberOfMatches(in: output, range: NSRange(output.startIndex..., in: output)) ?? 0
            best = max(best, n)
        }
        // "with 2 failures" (XCTest), "2 failed" (pytest/jest)
        if let re = try? NSRegularExpression(pattern: #"with (\d+) failures?|(\d+) failed"#),
           let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
            for i in 1...2 where m.range(at: i).location != NSNotFound {
                if let r = Range(m.range(at: i), in: output), let n = Int(output[r]) { best = max(best, n) }
            }
        }
        return best
    }

    /// Parece um comando de teste?
    public static func looksLikeTestCommand(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        return c.range(of: #"(^|\s|/)(test|tests|spec|pytest|jest|vitest|rspec|ctest)(\s|$|:)"#, options: .regularExpression) != nil
            || c.hasPrefix("go test") || c.hasPrefix("cargo test") || c.hasPrefix("swift test") || c.contains("npm test")
            || c.contains("run test") || c.hasPrefix("make check")
    }
}
