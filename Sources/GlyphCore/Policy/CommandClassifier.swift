import Foundation

/// Classifica um comando de shell na classe de ação mais arriscada que ele
/// pode ter. Na dúvida, escolhe a mais conservadora: comando desconhecido é
/// `external_effect` (sempre pede).
///
/// É análise estática simples, não um interpretador de shell. Qualquer coisa
/// que ele não entende (substituição de comando, `eval`) sobe de classe.
public enum CommandClassifier {
    public struct Verdict: Sendable, Equatable {
        public var actionClass: ActionClass
        /// Proibido mesmo com aprovação (`sudo`, …).
        public var forbidden: Bool
        public var reason: String

        public init(_ c: ActionClass, forbidden: Bool = false, _ reason: String) {
            self.actionClass = c
            self.forbidden = forbidden
            self.reason = reason
        }
    }

    static let order: [ActionClass] = [.read, .networkRead, .compute, .localWrite, .externalEffect, .destructive, .financial]

    static func rank(_ c: ActionClass) -> Int { order.firstIndex(of: c) ?? order.count }

    public static func max(_ a: ActionClass, _ b: ActionClass) -> ActionClass { rank(a) >= rank(b) ? a : b }

    static let readOnly: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "rg", "ag", "pwd", "echo", "printf", "which", "whoami",
        "date", "stat", "file", "du", "df", "tree", "jq", "sort", "uniq", "cut", "tr", "less", "more", "basename",
        "dirname", "realpath", "readlink", "uname", "hostname", "sw_vers", "true", "false", "test", "[", "diff",
        "cmp", "column", "nl", "fold", "comm", "md5", "shasum", "sha256sum", "md5sum", "env", "printenv", "id",
        "ps", "top", "uptime", "type", "command", "man", "xxd", "hexdump", "strings", "otool", "nm", "lsof",
    ]

    static let computeFirstWords: Set<String> = ["pytest", "tsc", "eslint", "swiftlint", "swiftformat", "ruff",
                                                 "mypy", "flake8", "rspec", "jest", "vitest", "ctest", "xcpretty"]

    static let destructiveWords: Set<String> = ["rm", "rmdir", "shred", "dd", "mkfs", "truncate", "srm", "diskutil",
                                                "killall", "kill", "pkill", "launchctl", "defaults", "crontab"]

    static let networkWriteWords: Set<String> = ["ssh", "scp", "sftp", "rsync", "ftp", "telnet", "nc", "netcat",
                                                 "mail", "sendmail", "osascript", "open", "xdg-open", "say"]

    static let forbiddenWords: Set<String> = ["sudo", "su", "doas", "pkexec", "chown", "passwd", "visudo"]

    public static func classify(_ command: String) -> Verdict {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Verdict(.read, "vazio") }
        if trimmed.contains("$(") || trimmed.contains("`") || trimmed.contains("<(") {
            return Verdict(.externalEffect, "substituição de comando: não dá para analisar")
        }
        var worst = Verdict(.read, "só leitura")
        for segment in segments(trimmed) {
            let v = classifySegment(segment)
            if v.forbidden { return v }
            if rank(v.actionClass) > rank(worst.actionClass) { worst = v }
        }
        return worst
    }

    /// Divide por `;`, `&&`, `||`, `|` e quebras de linha (fora de aspas).
    static func segments(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var single = false, double = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !double { single.toggle() }
            if c == "\"" && !single { double.toggle() }
            if !single && !double && (c == ";" || c == "|" || c == "&" || c == "\n") {
                // `>&2`, `2>&1` não separam comando.
                if c == "&", i > 0, chars[i - 1] == ">" { cur.append(c); i += 1; continue }
                if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
                cur = ""
                while i + 1 < chars.count, chars[i + 1] == c { i += 1 }
                i += 1
                continue
            }
            cur.append(c)
            i += 1
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out
    }

    /// Palavras, respeitando aspas simples e duplas.
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var single = false, double = false, has = false
        for c in s {
            if c == "'" && !double { single.toggle(); has = true; continue }
            if c == "\"" && !single { double.toggle(); has = true; continue }
            if c == " " && !single && !double {
                if has || !cur.isEmpty { out.append(cur) }
                cur = ""; has = false
                continue
            }
            cur.append(c)
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    static func classifySegment(_ segment: String) -> Verdict {
        var w = words(segment.trimmingCharacters(in: .whitespaces))
        // Atribuições de ambiente na frente (`FOO=1 cmd`).
        while let f = w.first, f.contains("="), !f.hasPrefix("-"), f.first?.isLetter == true { w.removeFirst() }
        guard var cmd = w.first else { return Verdict(.read, "vazio") }
        cmd = (cmd as NSString).lastPathComponent
        let args = Array(w.dropFirst())

        if forbiddenWords.contains(cmd) { return Verdict(.destructive, forbidden: true, "\(cmd) é proibido") }
        if cmd == "eval" || cmd == "exec" || cmd == "source" || cmd == "." || cmd == "sh" || cmd == "bash" || cmd == "zsh" {
            return Verdict(.externalEffect, "\(cmd) executa código arbitrário")
        }

        // Redirecionamento de saída escreve arquivo.
        var base: Verdict
        let redirects = writesFile(segment)

        switch cmd {
        case "git": base = classifyGit(args)
        case "curl", "wget", "http", "xh": base = classifyHTTP(cmd, args)
        case "find":
            base = args.contains("-delete") || args.contains("-exec") || args.contains("-execdir")
                ? Verdict(.destructive, "find com -delete/-exec") : Verdict(.read, "find")
        case "sed", "perl":
            base = args.contains(where: { $0.hasPrefix("-i") }) ? Verdict(.localWrite, "\(cmd) -i") : Verdict(.read, cmd)
        case "awk": base = Verdict(.read, "awk")
        case "gh": base = classifyGH(args)
        case "swift", "cargo", "go", "npm", "pnpm", "yarn", "bun", "make", "xcodebuild", "python", "python3",
             "node", "deno", "gradle", "./gradlew", "mvn", "bundle", "rake", "dotnet", "mix", "zig":
            base = classifyBuildTool(cmd, args)
        case "mkdir", "touch", "cp", "mv", "ln", "tee", "chmod", "tar", "unzip", "zip", "gzip", "gunzip", "patch":
            base = Verdict(.localWrite, cmd)
        default:
            if readOnly.contains(cmd) { base = Verdict(.read, cmd) }
            else if computeFirstWords.contains(cmd) { base = Verdict(.compute, cmd) }
            else if destructiveWords.contains(cmd) { base = Verdict(.destructive, cmd) }
            else if networkWriteWords.contains(cmd) { base = Verdict(.externalEffect, cmd) }
            else { base = Verdict(.externalEffect, "comando desconhecido: \(cmd)") }
        }
        if redirects, rank(base.actionClass) < rank(.localWrite) {
            base = Verdict(.localWrite, "redirecionamento para arquivo")
        }
        return base
    }

    /// Há um `>` (ou `>>`) fora de aspas que grava num arquivo de verdade?
    /// `2>/dev/null`, `>&2` e `2>&1` não contam.
    static func writesFile(_ s: String) -> Bool {
        let c = Array(s)
        var single = false, double = false
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "'" && !double { single.toggle() }
            if ch == "\"" && !single { double.toggle() }
            if ch == ">" && !single && !double {
                var j = i + 1
                if j < c.count, c[j] == ">" { j += 1 }
                if j < c.count, c[j] == "&" { i = j + 1; continue }
                while j < c.count, c[j] == " " { j += 1 }
                let target = String(c[j...].prefix { $0 != " " && $0 != ";" && $0 != "|" })
                if target != "/dev/null" && !target.isEmpty { return true }
                i = j
                continue
            }
            i += 1
        }
        return false
    }

    static func classifyGit(_ a: [String]) -> Verdict {
        guard let sub = a.first(where: { !$0.hasPrefix("-") }) else { return Verdict(.read, "git") }
        let rest = Array(a.drop(while: { $0 != sub }).dropFirst())
        switch sub {
        case "status", "log", "diff", "show", "blame", "rev-parse", "describe", "ls-files", "shortlog", "grep",
             "reflog", "cat-file", "whatchanged":
            return Verdict(.read, "git \(sub)")
        case "config":
            return rest.isEmpty || rest.contains("--get") || rest.contains("--list") || rest.contains("-l")
                ? Verdict(.read, "git config") : Verdict(.localWrite, "git config")
        case "remote":
            return rest.isEmpty || rest == ["-v"] ? Verdict(.read, "git remote") : Verdict(.localWrite, "git remote")
        case "branch":
            if rest.contains("-D") || rest.contains("--delete") && rest.contains("--force") { return Verdict(.destructive, "git branch -D") }
            return rest.isEmpty || rest.allSatisfy({ $0.hasPrefix("-") && $0 != "-d" && $0 != "-m" })
                ? Verdict(.read, "git branch") : Verdict(.localWrite, "git branch")
        case "fetch": return Verdict(.networkRead, "git fetch")
        case "pull": return Verdict(.localWrite, "git pull")
        case "clone": return Verdict(.localWrite, "git clone")
        case "add", "commit", "stash", "switch", "merge", "cherry-pick", "tag", "worktree", "restore", "rebase", "mv", "init":
            if sub == "restore" || (sub == "stash" && rest.first == "drop") { return Verdict(.destructive, "git \(sub)") }
            return Verdict(.localWrite, "git \(sub)")
        case "checkout":
            return rest.contains("--") || rest.contains(".") ? Verdict(.destructive, "git checkout descarta mudanças")
                                                             : Verdict(.localWrite, "git checkout")
        case "reset":
            return rest.contains("--hard") ? Verdict(.destructive, "git reset --hard") : Verdict(.localWrite, "git reset")
        case "clean": return Verdict(.destructive, "git clean")
        case "rm": return Verdict(.destructive, "git rm")
        case "push":
            if rest.contains(where: { $0 == "-f" || $0.hasPrefix("--force") || $0.hasPrefix("+") || $0.contains(":+") }) {
                return Verdict(.destructive, "push forçado")
            }
            if rest.contains(where: { $0 == "--delete" || $0 == "-d" || $0.hasPrefix(":") }) {
                return Verdict(.destructive, "push apagando ramo remoto")
            }
            let targets = rest.filter { !$0.hasPrefix("-") }.dropFirst()
            if targets.contains(where: { ["main", "master", "trunk"].contains($0.split(separator: ":").last.map(String.init) ?? $0) }) {
                return Verdict(.destructive, "push na main")
            }
            return Verdict(.externalEffect, "git push")
        default:
            return Verdict(.externalEffect, "git \(sub)")
        }
    }

    static func classifyHTTP(_ cmd: String, _ a: [String]) -> Verdict {
        // Mesmo com -X GET, -d/-F/-T podem enviar dados (inclusive de um arquivo).
        let shortDataFlags = ["-d", "-F", "-T", "-K"]
        let longDataFlags = ["--data", "--data-raw", "--data-binary", "--data-urlencode",
                             "--form", "--form-string", "--upload-file", "--post-data", "--post-file",
                             "--json", "--url-query", "--config"]
        if a.contains(where: { arg in
            shortDataFlags.contains(where: { arg.hasPrefix($0) })
                || longDataFlags.contains(where: { arg == $0 || arg.hasPrefix($0 + "=") })
        }) {
            return Verdict(.externalEffect, "\(cmd) enviando dados")
        }
        for (i, arg) in a.enumerated() {
            if ["-X", "--request", "--method"].contains(arg) {
                guard i + 1 < a.count, ["GET", "HEAD"].contains(a[i + 1].uppercased()) else {
                    return Verdict(.externalEffect, "\(cmd) método não seguro")
                }
            } else if arg.hasPrefix("-X"), arg != "-X" {
                guard ["GET", "HEAD"].contains(String(arg.dropFirst(2)).uppercased()) else {
                    return Verdict(.externalEffect, "\(cmd) método não seguro")
                }
            } else if let flag = ["--request=", "--method="].first(where: { arg.hasPrefix($0) }) {
                guard ["GET", "HEAD"].contains(String(arg.dropFirst(flag.count)).uppercased()) else {
                    return Verdict(.externalEffect, "\(cmd) método não seguro")
                }
            }
        }
        if a.contains(where: { $0 == "-o" || $0 == "-O" || $0.hasPrefix("--output") }) || cmd == "wget" {
            return Verdict(.localWrite, "\(cmd) salvando arquivo")
        }
        return Verdict(.networkRead, "\(cmd) GET")
    }

    static func classifyGH(_ a: [String]) -> Verdict {
        let sub = a.prefix(2).joined(separator: " ")
        if a.first == "api" {
            // gh api usa POST implicitamente quando recebe -f/-F/--input.
            let writeFlags = ["-f", "-F", "-X", "--field", "--raw-field", "--input", "--method"]
            let sendsData = a.dropFirst().contains { arg in
                writeFlags.contains(where: { arg == $0 || arg.hasPrefix($0 + "=")
                    || (["-f", "-F", "-X"].contains($0) && arg.hasPrefix($0)) })
            }
            return sendsData ? Verdict(.externalEffect, "gh api enviando dados")
                             : Verdict(.networkRead, "gh api")
        }
        if sub.hasPrefix("pr view") || sub.hasPrefix("pr list") || sub.hasPrefix("pr diff") || sub.hasPrefix("pr checks")
            || sub.hasPrefix("issue view") || sub.hasPrefix("issue list") || sub.hasPrefix("run view")
            || sub.hasPrefix("run list") || sub.hasPrefix("repo view") {
            return Verdict(.networkRead, "gh \(sub)")
        }
        if sub.hasPrefix("repo delete") || sub.hasPrefix("release delete") { return Verdict(.destructive, "gh \(sub)") }
        return Verdict(.externalEffect, "gh \(sub)")
    }

    static func classifyBuildTool(_ cmd: String, _ a: [String]) -> Verdict {
        let sub = a.first ?? ""
        let joined = a.prefix(2).joined(separator: " ")
        let publish = ["publish", "deploy", "upload", "release", "push"]
        let second = a.count > 1 ? a[1] : ""
        if publish.contains(sub) || (sub == "run" && publish.contains(second)) {
            return Verdict(.externalEffect, "\(cmd) \(sub): publica")
        }
        switch cmd {
        case "swift":
            if ["test", "build"].contains(sub) || joined == "package describe" { return Verdict(.compute, "swift \(sub)") }
            if sub == "run" || sub.hasSuffix(".swift") { return Verdict(.externalEffect, "swift \(sub): executa código") }
            return Verdict(.localWrite, "swift \(sub)")
        case "cargo":
            return ["test", "build", "check", "clippy", "fmt"].contains(sub) && !a.contains("--fix")
                ? Verdict(.compute, "cargo \(sub)") : Verdict(.localWrite, "cargo \(sub)")
        case "go":
            return ["test", "build", "vet"].contains(sub) ? Verdict(.compute, "go \(sub)") : Verdict(.localWrite, "go \(sub)")
        case "npm", "pnpm", "yarn", "bun":
            if sub == "test" || joined == "run test" || joined == "run lint" || joined == "run build" || sub == "t" {
                return Verdict(.compute, "\(cmd) \(joined)")
            }
            return Verdict(.localWrite, "\(cmd) \(sub)")
        case "make":
            return sub.isEmpty || ["test", "check", "build", "all", "lint"].contains(sub)
                ? Verdict(.compute, "make \(sub)") : Verdict(.localWrite, "make \(sub)")
        case "xcodebuild":
            return a.contains("test") || a.contains("build") ? Verdict(.compute, "xcodebuild") : Verdict(.localWrite, "xcodebuild")
        case "python", "python3":
            return joined.hasPrefix("-m pytest") || joined.hasPrefix("-m unittest") || joined.hasPrefix("-m mypy")
                ? Verdict(.compute, "\(cmd) -m teste") : Verdict(.externalEffect, "\(cmd): executa código")
        default:
            return a.contains("test") || a.contains("build") ? Verdict(.compute, "\(cmd) \(sub)") : Verdict(.externalEffect, "\(cmd) \(sub)")
        }
    }
}
