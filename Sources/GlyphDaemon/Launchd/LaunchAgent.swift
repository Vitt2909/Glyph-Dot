import Foundation

/// O `glyphd` como LaunchAgent do usuário (`~/Library/LaunchAgents`).
public struct LaunchAgent: Sendable, Equatable {
    public static let label = "dev.glyph.glyphd"

    public var executable: String
    public var logDir: String

    public init(executable: String, logDir: String) {
        self.executable = executable
        self.logDir = logDir
    }

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Conteúdo do plist. `KeepAlive` só reinicia se o processo morrer com erro.
    public var plist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(Self.label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(xmlEscape(executable))</string>
        \t\t<string>run</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<dict>
        \t\t<key>SuccessfulExit</key>
        \t\t<false/>
        \t</dict>
        \t<key>ProcessType</key>
        \t<string>Background</string>
        \t<key>LowPriorityIO</key>
        \t<true/>
        \t<key>StandardOutPath</key>
        \t<string>\(xmlEscape(logDir))/glyphd.out.log</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(xmlEscape(logDir))/glyphd.err.log</string>
        </dict>
        </plist>

        """
    }

    func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    #if os(macOS)
    public func install() throws {
        try FileManager.default.createDirectory(at: Self.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        try plist.write(to: Self.plistURL, atomically: true, encoding: .utf8)
        _ = Self.launchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        let status = Self.launchctl(["bootstrap", "gui/\(getuid())", Self.plistURL.path])
        guard status == 0 else { throw NSError(domain: "launchctl", code: Int(status)) }
    }

    public static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    #endif
}
