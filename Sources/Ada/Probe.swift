import AppKit
import ServiceManagement

/// `Ada --probe` → Müzik'e adım adım soru sorup aldığı cevabı (ya da hatayı) yazar.
/// Şarkı görünmüyorsa sorunun nerede olduğunu bulmak için.
@MainActor
enum Probe {
    static func run() {
        // İsteğe bağlı: belirli bir şarkının sözü var mı?  --song "Ad" --artist "Sanatçı"
        if let title = value(after: "--song") {
            let artist = value(after: "--artist") ?? ""
            let track = Track(id: title, title: title, artist: artist, album: "", duration: 0)
            print("• sözler (\(title) – \(artist)): \(lyricsSummary(for: track))")
            fflush(stdout)
            return
        }

        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let players = PlayerApp.allCases.filter { running.contains($0.rawValue) }
        print("Açık oynatıcılar: \(players.map(\.displayName))")

        if players.contains(.music) {
            let music = "tell application id \"com.apple.Music\" to "
            let checks: [(String, String)] = [
                ("çalma durumu", music + "get (player state as text)"),
                ("şarkı türü", music + "get (class of current track as text)"),
                ("şarkı adı", music + "get name of current track"),
                ("sanatçı", music + "get artist of current track"),
                ("yayın başlığı", music + "get current stream title"),
                ("konum", music + "get player position"),
                ("Ada'nın asıl betiği", Scripts.music),
                ("kapak resmi", Scripts.musicArtwork),
            ]
            for (label, source) in checks {
                print("• \(label): \(evaluate(source))")
            }

            // Sözler: sadece bulundu mu ve kaç satır (söz metnini yazmıyoruz).
            if let script = NSAppleScript(source: Scripts.music) {
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if error == nil, let track = NowPlaying.parse(result, app: .music)?.track {
                    print("• sözler (lrclib.net): \(lyricsSummary(for: track))")
                }
            }
        }
        fflush(stdout)
    }

    /// `Ada --login-status` → "Mac açılınca başlat" açık mı?
    static func printLaunchAtLoginStatus() {
        let text: String
        switch SMAppService.mainApp.status {
        case .enabled: text = "açık"
        case .notRegistered: text = "kapalı"
        case .requiresApproval: text = "onay bekliyor (Sistem Ayarları → Genel → Giriş Öğeleri)"
        case .notFound: text = "bulunamadı"
        @unknown default: text = "bilinmiyor"
        }
        print("Mac açılınca başlat: \(text)  [\(Bundle.main.bundlePath)]")
        fflush(stdout)
    }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func lyricsSummary(for track: Track) -> String {
        final class Box: @unchecked Sendable {
            var value: LyricsState??
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = .some(await LyricsService.fetch(track))
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value {
        case .some(.some(.synced(let lines))): return "zamanlı, \(lines.count) satır"
        case .some(.some(.plain(let lines))): return "zamansız, \(lines.count) satır"
        case .some(.some(.instrumental)): return "enstrümantal"
        case .some(.some(.notFound)): return "bulunamadı"
        case .some(.none): return "ağ hatası"
        default: return "?"
        }
    }

    private static func evaluate(_ source: String) -> String {
        guard let script = NSAppleScript(source: source) else { return "betik oluşturulamadı" }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] ?? "?"
            let message = error[NSAppleScript.errorMessage] ?? ""
            return "HATA \(number): \(message)"
        }
        return describe(result)
    }

    private static func describe(_ descriptor: NSAppleEventDescriptor) -> String {
        if descriptor.numberOfItems > 0 {
            let items = (1...descriptor.numberOfItems).map { index -> String in
                guard let item = descriptor.atIndex(index) else { return "?" }
                return describe(item)
            }
            return "{" + items.joined(separator: ", ") + "}"
        }
        if let text = descriptor.stringValue { return "\"\(text)\"" }
        return "<\(fourCharCode(descriptor.descriptorType))>"
    }

    private static func fourCharCode(_ code: DescType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }
}
