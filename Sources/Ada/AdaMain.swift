import AppKit

/// Giriş noktası.
/// - Normal açılış: çentikteki adayı başlatır.
/// - `--snapshot <klasör>`: her halin PNG'sini çıkarıp kapanır
///   (ekrana bir şey açmadan tasarımı görmek için).
@main
enum AdaMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        signal(SIGPIPE, SIG_IGN) // kapanmış bir boruya / sokete yazınca çökmesin
        // Claude Code izin kancası: Ada --claude-permission (stdin: kancanın JSON'u)
        if arguments.contains("--claude-permission") {
            PermissionHook.run()
            return
        }
        // Claude Code durum satırı: Ada --statusline (kullanım limitlerini Ada'ya iletir)
        if arguments.contains("--statusline") {
            UsageStatusLine.run()
            return
        }
        // Terminalden mesaj: Ada --say "Kod bitti!"
        if let index = arguments.firstIndex(of: "--say") {
            let text = arguments[(index + 1)...].joined(separator: " ")
            Messenger.post(text.isEmpty ? "Bitti!" : text, from: .user)
            return
        }
        // Claude Code kancaları: Ada --claude (iş bitti) / Ada --claude-event start|tool|wait|done
        if arguments.contains("--claude") {
            Messenger.postClaudeEvent(.done)
            return
        }
        if let index = arguments.firstIndex(of: "--claude-event") {
            let name = index + 1 < arguments.count ? arguments[index + 1] : ""
            if let kind = ClaudeEventKind(rawValue: name) { Messenger.postClaudeEvent(kind) }
            return
        }
        if arguments.contains("--login-status") {
            Probe.printLaunchAtLoginStatus()
            return
        }
        if arguments.contains("--probe") {
            Probe.run()
            return
        }
        if let index = arguments.firstIndex(of: "--snapshot") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "snapshots"
            Snapshot.renderAll(to: URL(fileURLWithPath: folder))
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Dock'ta ikon çıkmasın
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
