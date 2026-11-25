import Foundation

/// Müzik uygulamalarına sorulan AppleScript'ler.
///
/// Not: Değişken adları bilerek `ada...` ile başlıyor. AppleScript'te `st`, `nd`, `rd`, `th`
/// gibi kısa adlar ayrılmış kelime (1st, 2nd... sıra sayıları için), ayrıca `name`, `artist`
/// gibi adlar Müzik'in kendi kelimeleriyle çakışıyor. Çakışınca betik hiç derlenmiyor.
enum Scripts {
    static func status(for app: PlayerApp) -> String {
        switch app {
        case .music: return music
        case .spotify: return spotify
        }
    }

    /// Dönen liste: {durum, ad, sanatçı, albüm, süre(sn), konum(sn), id, kapak linki}
    static let music = """
        if application id "com.apple.Music" is not running then return {"off"}
        with timeout of 3 seconds
            tell application id "com.apple.Music"
                set adaState to (player state as text)
                if adaState is "stopped" then return {"stopped"}
                try
                    set adaTrack to current track
                on error
                    return {"stopped"}
                end try
                set adaName to ""
                set adaArtist to ""
                set adaAlbum to ""
                set adaDuration to 0
                set adaID to ""
                set adaPosition to 0
                try
                    set adaName to name of adaTrack
                end try
                try
                    set adaArtist to artist of adaTrack
                end try
                try
                    set adaAlbum to album of adaTrack
                end try
                try
                    set adaDuration to duration of adaTrack
                end try
                try
                    set adaID to persistent ID of adaTrack
                end try
                try
                    set adaPosition to player position
                end try
                return {adaState, adaName, adaArtist, adaAlbum, adaDuration, adaPosition, adaID, ""}
            end tell
        end timeout
        """

    static let spotify = """
        if application id "com.spotify.client" is not running then return {"off"}
        with timeout of 3 seconds
            tell application id "com.spotify.client"
                set adaState to (player state as text)
                if adaState is "stopped" then return {"stopped"}
                try
                    set adaTrack to current track
                on error
                    return {"stopped"}
                end try
                set adaName to ""
                set adaArtist to ""
                set adaAlbum to ""
                set adaDuration to 0
                set adaID to ""
                set adaArtwork to ""
                set adaPosition to 0
                try
                    set adaName to name of adaTrack
                end try
                try
                    set adaArtist to artist of adaTrack
                end try
                try
                    set adaAlbum to album of adaTrack
                end try
                try
                    set adaDuration to (duration of adaTrack) / 1000
                end try
                try
                    set adaID to id of adaTrack
                end try
                try
                    set adaArtwork to artwork url of adaTrack
                end try
                try
                    set adaPosition to player position
                end try
                return {adaState, adaName, adaArtist, adaAlbum, adaDuration, adaPosition, adaID, adaArtwork}
            end tell
        end timeout
        """

    /// Çalan şarkının kapak resmi (ham veri).
    static let musicArtwork = """
        with timeout of 3 seconds
            tell application id "com.apple.Music"
                try
                    return raw data of artwork 1 of current track
                on error
                    return ""
                end try
            end tell
        end timeout
        """
}

/// AppleScript'leri arka planda, sırayla çalıştırır (arayüz donmasın diye).
/// Sonuçları ana thread'e geri yollar.
final class ScriptBridge: @unchecked Sendable {
    struct Output {
        var descriptor: NSAppleEventDescriptor?
        var errorNumber: Int?
    }

    private let queue = DispatchQueue(label: "ada.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:] // sadece queue üzerinde kullanılır

    func run(_ sources: [String], cache: Bool = true, completion: @escaping ([Output]) -> Void) {
        queue.async {
            let outputs = sources.map { self.execute($0, cache: cache) }
            DispatchQueue.main.async { completion(outputs) }
        }
    }

    private func execute(_ source: String, cache: Bool) -> Output {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return Output() }
            var error: NSDictionary?
            guard fresh.compileAndReturnError(&error) else {
                return Output(descriptor: nil, errorNumber: error?[NSAppleScript.errorNumber] as? Int)
            }
            if cache { compiled[source] = fresh }
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return Output(descriptor: nil, errorNumber: error[NSAppleScript.errorNumber] as? Int)
        }
        return Output(descriptor: result, errorNumber: nil)
    }
}
