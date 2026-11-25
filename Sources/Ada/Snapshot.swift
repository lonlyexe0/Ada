import AppKit
import SwiftUI

/// `Ada --snapshot <klasör>` → adanın her halini PNG olarak çizer.
/// Ekrana pencere açmadan tasarımı kontrol etmek için. Sözler uydurma örnek satırlardır.
@MainActor
enum Snapshot {
    /// Resim çıkarılırken true: Core Animation görünümleri yerine sabit çizimler kullanılır
    /// (resim çizici AppKit görünümlerini çizemiyor).
    static var isRendering = false

    private struct Case {
        let name: String
        let mode: IslandMode
        var music = true
        var lyrics = false
        var swipe: CGFloat = 0
        var message: IslandMessage? = nil
        var claude: ClaudeActivity.Phase? = nil
        var finished = false
        var unseen = false
        var musicIdle = false
    }

    static func renderAll(to folder: URL) {
        _ = NSApplication.shared
        isRendering = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let screen = IslandController.targetScreen()
        let notch = screen.map(IslandController.metrics(for:))
            ?? NotchMetrics(width: 185, height: 32, hasNotch: true)
        print("Ekran: \(screen?.localizedName ?? "?")")
        print("Çentik: \(notch)")
        if let screen {
            print("Ekran çerçevesi: \(screen.frame)  Pencere: \(IslandController.windowFrame(on: screen, notch: notch))")
        }

        let state = IslandState()
        state.notch = notch
        let player = NowPlaying()
        let battery = BatteryMonitor(preview: true)
        let lyrics = LyricsStore()
        let claude = ClaudeActivity()

        let expanded = IslandLayout(notch: notch, showsLyrics: true, showsClaude: true).expandedSize
        let canvas = CGSize(width: expanded.width + 80, height: expanded.height + 50)

        let cases = [
            Case(name: "01-kapali", mode: .closed),
            Case(name: "02-muzik", mode: .music),
            Case(name: "03-sarj", mode: .charging),
            Case(name: "04-acik-sozlu", mode: .expanded, lyrics: true),
            Case(name: "05-acik-sozsuz", mode: .expanded),
            Case(name: "06-acik-bos", mode: .expanded, music: false),
            Case(name: "07-saga-kaydirma", mode: .expanded, lyrics: true, swipe: 0.9),
            Case(name: "08-claude-bitti", mode: .message,
                 message: IslandMessage(text: "İşim bitti · Ada", sender: .claude)),
            Case(name: "09-terminal-mesaj", mode: .message,
                 message: IslandMessage(text: "lab7.py bitti!", sender: .user)),
            Case(name: "10-claude-calisiyor", mode: .claude, music: false, claude: .working),
            Case(name: "11-claude-onay", mode: .claudeWaiting, music: false, claude: .waiting),
            Case(name: "12-muzik-claude", mode: .music, claude: .working),
            Case(name: "13-acik-claude", mode: .expanded, lyrics: true, claude: .working),
            Case(name: "14-acik-claude-bitti", mode: .expanded, music: false, finished: true),
            Case(name: "15-claude-rozet", mode: .claudeDone, music: false, unseen: true),
            Case(name: "16-muzik-rozet", mode: .music, unseen: true),
            Case(name: "17-acik-muzik-bosta", mode: .expanded, musicIdle: true),
        ]

        for item in cases {
            player.loadPreview(withMusic: item.music, idle: item.musicIdle)
            lyrics.setPreview(item.lyrics ? .synced(LyricsStore.previewLines) : .none)
            claude.loadPreview(item.claude, finished: item.finished, unseen: item.unseen)
            state.forcedMode = item.mode
            state.swipeProgress = item.swipe
            state.message = item.message
            state.lastSender = (item.message?.sender == .claude || item.claude == .waiting) ? .claude : .user
            let view = IslandRootView(state: state, player: player, battery: battery, lyrics: lyrics, claude: claude)
                .frame(width: canvas.width, height: canvas.height)
                .background(Color(white: 0.62))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                print("Çizilemedi: \(item.name)")
                continue
            }
            let url = folder.appendingPathComponent("\(item.name).png")
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try? data?.write(to: url)
            print("→ \(url.path)")
        }
    }
}
