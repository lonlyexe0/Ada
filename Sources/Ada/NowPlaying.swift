import AppKit
import SwiftUI

/// Desteklenen müzik uygulamaları.
enum PlayerApp: String, CaseIterable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var displayName: String {
        switch self {
        case .music: return "Müzik"
        case .spotify: return "Spotify"
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .spotify: return "waveform"
        }
    }
}

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double // saniye
}

/// Bir müzik uygulamasından tek seferde okunan durum.
struct PlayerSnapshot {
    var app: PlayerApp
    var isPlaying: Bool
    var track: Track?
    var position: Double
    var artworkURL: String?
}

/// Şu an çalan şarkıyı takip eder ve kontrol eder (AppleScript ile).
@MainActor
final class NowPlaying: ObservableObject {
    @Published private(set) var app: PlayerApp?
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    @Published private(set) var permissionDenied = false
    /// İlerleme çubuğu sürüklenirken (0...1), değilse nil.
    @Published var scrubFraction: Double?
    /// Müzik bir süredir duraklatılmışsa true: büyük panel normal haline (saat, tarih) döner.
    @Published private(set) var musicIdle = false
    private var idleTask: Task<Void, Never>?
    /// Bu kadar süre duraklatılmış kalınca panel normale döner.
    private static let idleAfter: TimeInterval = 120

    /// Şarkı değişince çağrılır (yeni şarkı ya da müzik bittiyse nil). Sözleri yüklemek için.
    var trackDidChange: ((Track?) -> Void)?

    private var positionDate = Date()
    private let bridge = ScriptBridge()
    private var observers: [NSObjectProtocol] = []
    private var fetching = false
    private var generation = 0
    private var artworkKey: String?
    private var started = false

    // MARK: Başlatma

    func start() {
        guard !started else { return }
        started = true

        // Müzik / Spotify şarkı değişince ya da durunca sisteme haber yayınlar.
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            })
        }
        // Müzik açılıp kapanınca da tekrar bak.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            })
        }
        // İlerleme çubuğu kaymasın diye ara ara yokla.
        Task { [weak self] in
            while let self {
                self.refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: Okuma

    /// Son okunan konumdan bu yana geçen süreyi ekleyerek şarkının şu anki saniyesini tahmin eder.
    func currentPosition(at date: Date) -> Double {
        guard let track else { return 0 }
        var value = position
        if isPlaying { value += date.timeIntervalSince(positionDate) }
        if track.duration > 0 { value = min(value, track.duration) }
        return max(0, value)
    }

    func refresh() {
        guard !fetching else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        // Sadece açık olan uygulamalara sor (kapalıysa AppleScript onu açmasın).
        let apps = PlayerApp.allCases.filter { running.contains($0.rawValue) }
        guard !apps.isEmpty else {
            clear()
            return
        }
        fetching = true
        let startedGeneration = generation
        bridge.run(apps.map(Scripts.status(for:))) { [weak self] outputs in
            guard let self else { return }
            self.fetching = false
            // Bu arada bir butona basıldıysa bu sonuç eskidir, tekrar sor.
            guard startedGeneration == self.generation else {
                self.refresh()
                return
            }
            var snapshots: [PlayerSnapshot] = []
            var denied = false
            for (app, output) in zip(apps, outputs) {
                if output.errorNumber == -1743 { denied = true } // kullanıcı izin vermedi
                if let snapshot = Self.parse(output.descriptor, app: app) { snapshots.append(snapshot) }
            }
            if self.permissionDenied != denied { self.permissionDenied = denied }
            self.apply(self.choose(snapshots))
        }
    }

    private func refreshSoon() {
        refresh()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.refresh()
        }
    }

    /// Birden fazla uygulama açıksa: çalanı, yoksa en son göstereni seç.
    private func choose(_ snapshots: [PlayerSnapshot]) -> PlayerSnapshot? {
        let withTrack = snapshots.filter { $0.track != nil }
        if let playing = withTrack.first(where: \.isPlaying) { return playing }
        if let current = app, let same = withTrack.first(where: { $0.app == current }) { return same }
        return withTrack.first
    }

    private func apply(_ snapshot: PlayerSnapshot?) {
        guard let snapshot, let newTrack = snapshot.track else {
            clear()
            return
        }
        let now = Date()
        let trackChanged = newTrack.id != track?.id || newTrack.title != track?.title
        let playStateChanged = snapshot.isPlaying != isPlaying
        let drift = abs(currentPosition(at: now) - snapshot.position)

        if app != snapshot.app { app = snapshot.app }
        if track != newTrack { track = newTrack }
        if playStateChanged { isPlaying = snapshot.isPlaying }
        // Sözler saniyesi saniyesine aksın diye konumu sık düzelt.
        if trackChanged || playStateChanged || drift > 0.35 {
            position = snapshot.position
            positionDate = now
        }
        if trackChanged {
            loadArtwork(for: snapshot)
            trackDidChange?(newTrack)
        }
        if trackChanged || playStateChanged { updateIdleTimer() }
    }

    /// Çalıyorsa "boşta" değil; duraklatıldıysa 2 dk sonra "boşta" say.
    private func updateIdleTimer() {
        idleTask?.cancel()
        if musicIdle { musicIdle = false } // bir şey değişti (çal/duraklat/şarkı): müzik ekranı geri gelsin
        guard !isPlaying, track != nil else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleAfter * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isPlaying, self.track != nil else { return }
            self.musicIdle = true
        }
    }

    private func clear() {
        if app != nil { app = nil }
        if track != nil {
            track = nil
            trackDidChange?(nil)
        }
        if isPlaying { isPlaying = false }
        if artwork != nil { setArtwork(nil) }
        artworkKey = nil
        idleTask?.cancel()
        if musicIdle { musicIdle = false }
    }

    // MARK: Kapak resmi

    private func loadArtwork(for snapshot: PlayerSnapshot) {
        guard let track = snapshot.track else { return }
        let key = snapshot.app.rawValue + ":" + track.id
        guard key != artworkKey else { return }
        artworkKey = key

        switch snapshot.app {
        case .music:
            bridge.run([Scripts.musicArtwork]) { [weak self] outputs in
                guard let self, self.artworkKey == key else { return }
                if let descriptor = outputs.first?.descriptor, let image = NSImage(data: descriptor.data) {
                    self.setArtwork(image)
                } else {
                    self.setArtwork(nil)
                }
            }
        case .spotify:
            guard let link = snapshot.artworkURL, let url = URL(string: link) else {
                setArtwork(nil)
                return
            }
            Task { [weak self] in
                let result = try? await URLSession.shared.data(from: url)
                guard let self, self.artworkKey == key else { return }
                self.setArtwork(result.flatMap { NSImage(data: $0.0) })
            }
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        accent = image.map(Self.accentColor(for:)) ?? .white
    }

    // MARK: Kontroller

    func togglePlay() {
        let now = Date()
        position = currentPosition(at: now)
        positionDate = now
        isPlaying.toggle() // butona basınca ikon hemen değişsin
        updateIdleTimer()
        send("playpause")
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        position = max(0, seconds)
        positionDate = Date()
        send("set player position to \(Int(seconds.rounded()))")
    }

    private func send(_ command: String) {
        guard let app else { return }
        generation += 1
        let source = "tell application id \"\(app.rawValue)\" to \(command)"
        bridge.run([source], cache: false) { [weak self] _ in
            self?.refresh()
        }
    }

    func openMusicApp() { launch(bundleID: PlayerApp.music.rawValue) }
    func activatePlayer() { launch(bundleID: (app ?? .music).rawValue) }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Yardımcılar

    /// AppleScript'in döndürdüğü listeyi okur: {durum, ad, sanatçı, albüm, süre, konum, id, kapak linki}
    static func parse(_ descriptor: NSAppleEventDescriptor?, app: PlayerApp) -> PlayerSnapshot? {
        guard let descriptor, descriptor.numberOfItems >= 1,
              let state = descriptor.atIndex(1)?.stringValue, state != "off" else { return nil }
        let empty = PlayerSnapshot(app: app, isPlaying: false, track: nil, position: 0, artworkURL: nil)
        guard state != "stopped", descriptor.numberOfItems >= 8 else { return empty }

        func text(_ index: Int) -> String { descriptor.atIndex(index)?.stringValue ?? "" }
        let title = text(2)
        let id = text(7)
        guard !title.isEmpty || !id.isEmpty else { return empty }

        let track = Track(id: id.isEmpty ? title : id, title: title, artist: text(3), album: text(4),
                          duration: number(descriptor.atIndex(5)))
        let artwork = text(8)
        return PlayerSnapshot(app: app, isPlaying: state == "playing", track: track,
                              position: number(descriptor.atIndex(6)),
                              artworkURL: artwork.isEmpty ? nil : artwork)
    }

    private static func number(_ descriptor: NSAppleEventDescriptor?) -> Double {
        guard let descriptor else { return 0 }
        let value = descriptor.doubleValue
        if value != 0, value.isFinite { return value }
        // Türkçe sistemde ondalık ayıracı virgül olabilir.
        if let text = descriptor.stringValue, let parsed = Double(text.replacingOccurrences(of: ",", with: ".")) {
            return parsed
        }
        return 0
    }

    /// Kapak resminin ortalama rengi (ekolayzer ve çubuk bu renkte olur). Siyahta görünsün diye açılır.
    static func accentColor(for image: NSImage) -> Color {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return .white }
        let average = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(nsColor: NSColor(hue: hue, saturation: min(saturation * 1.15, 0.8),
                                      brightness: max(brightness, 0.8), alpha: 1))
    }

    // MARK: Önizleme (snapshot için sahte veri)

    func loadPreview(withMusic: Bool, idle: Bool = false) {
        defer {
            musicIdle = withMusic && idle
            if musicIdle { isPlaying = false }
        }
        if withMusic {
            app = .music
            track = Track(id: "demo", title: "Gece Yarısı Sürüşü", artist: "Ada Demo Grubu",
                          album: "Önizleme", duration: 214)
            isPlaying = true
            position = 83
            positionDate = Date()
            setArtwork(Self.sampleArtwork())
        } else {
            app = nil
            track = nil
            isPlaying = false
            setArtwork(nil)
        }
    }

    static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            let gradient = NSGradient(colors: [
                NSColor(srgbRed: 0.98, green: 0.42, blue: 0.38, alpha: 1),
                NSColor(srgbRed: 0.45, green: 0.22, blue: 0.86, alpha: 1),
            ])
            gradient?.draw(in: rect, angle: -50)
            return true
        }
    }
}
