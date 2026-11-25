import SwiftUI

/// Zamanlı söz satırı.
struct LyricLine: Equatable {
    let time: Double // saniye
    let text: String
}

enum LyricsState: Equatable {
    case none                 // şarkı yok
    case loading
    case synced([LyricLine])  // zamanlı (kayan) sözler
    case plain([String])      // zamansız sözler
    case instrumental
    case notFound
}

// MARK: - Depo

/// Çalan şarkının sözlerini getirir ve saklar.
@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var state: LyricsState = .none

    private var cache: [String: LyricsState] = [:]
    private var currentKey: String?
    private var task: Task<Void, Never>?

    /// Büyük panelde söz alanı gösterilecek mi?
    var hasContent: Bool {
        switch state {
        case .synced, .plain, .instrumental: return true
        case .none, .loading, .notFound: return false
        }
    }

    func load(for track: Track?) {
        task?.cancel()
        guard let track, !track.title.isEmpty else {
            currentKey = nil
            state = .none
            return
        }
        let key = (track.artist + "|" + track.title).lowercased()
        currentKey = key
        if let cached = cache[key] {
            state = cached
            return
        }
        state = .loading
        task = Task { [weak self] in
            let result = await LyricsService.fetch(track)
            guard let self, !Task.isCancelled, self.currentKey == key else { return }
            if let result { self.cache[key] = result } // ağ hatasını saklama, sonra tekrar denesin
            self.state = result ?? .notFound
        }
    }

    func setPreview(_ state: LyricsState) {
        self.state = state
    }

    /// Snapshot için uydurma örnek satırlar (gerçek bir şarkı sözü değil).
    static let previewLines: [LyricLine] = [
        LyricLine(time: 64, text: "Bunlar örnek satırlar"),
        LyricLine(time: 70, text: "Gerçek sözler lrclib.net'ten gelir"),
        LyricLine(time: 77, text: "Şarkı ilerledikçe yukarı kayarlar"),
        LyricLine(time: 82, text: "Şu an söylenen satır parlak görünür"),
        LyricLine(time: 88, text: "Sıradaki satır biraz daha soluk"),
        LyricLine(time: 94, text: "Ve böyle devam eder"),
    ]
}

// MARK: - LRCLIB

/// lrclib.net: ücretsiz, açık söz veritabanı. Anahtar gerektirmez.
/// Gönderilen: şarkı adı, sanatçı, albüm, süre.
enum LyricsService {
    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Ada/0.1 (macOS notch app)"]
        return URLSession(configuration: config)
    }()

    /// nil → ağ hatası (sonra tekrar denenebilir).
    static func fetch(_ track: Track) async -> LyricsState? {
        do {
            // 1) Birebir eşleşme (ad + sanatçı + albüm + süre)
            if let record = try await exactMatch(for: track), let state = state(from: record) {
                return state
            }
            // 2) Arama: önce tam adla, sonra "(feat. ...)", "- Remastered" gibi ekleri atarak
            var titles = [track.title]
            let cleaned = cleanTitle(track.title)
            if cleaned != track.title, !cleaned.isEmpty { titles.append(cleaned) }
            for title in titles {
                if let record = try await bestSearchMatch(title: title, for: track), let state = state(from: record) {
                    return state
                }
            }
            return .notFound
        } catch {
            return nil
        }
    }

    private static func exactMatch(for track: Track) async throws -> Record? {
        // Birebir eşleşme için albüm ve süre lazım; yoksa doğrudan aramaya geç.
        guard !track.album.isEmpty, track.duration > 0 else { return nil }
        let items = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist),
                     URLQueryItem(name: "album_name", value: track.album),
                     URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))]
        guard let data = try await get("https://lrclib.net/api/get", items) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func bestSearchMatch(title: String, for track: Track) async throws -> Record? {
        let items = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        guard let data = try await get("https://lrclib.net/api/search", items) else { return nil }
        let records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        let sameVersion = records.filter { record in
            guard track.duration > 0, let duration = record.duration else { return true }
            return abs(duration - track.duration) <= 10 // süresi çok farklıysa başka versiyondur
        }
        return sameVersion.min { score($0, track) < score($1, track) }
    }

    /// Küçük skor daha iyi: zamanlı sözü olan ve süresi en yakın olan.
    private static func score(_ record: Record, _ track: Track) -> Double {
        var value = 0.0
        if record.syncedLyrics?.isEmpty ?? true { value += 100 }
        if record.plainLyrics?.isEmpty ?? true, record.instrumental != true { value += 1000 }
        if track.duration > 0, let duration = record.duration { value += abs(duration - track.duration) }
        return value
    }

    /// 200 → veri, 4xx (bulunamadı / eksik bilgi) → nil, diğerleri → hata.
    private static func get(_ base: String, _ items: [URLQueryItem]) async throws -> Data? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items
        // "+" işareti boşluk sanılmasın
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (400..<500).contains(status) { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func state(from record: Record) -> LyricsState? {
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        if record.instrumental == true { return .instrumental }
        return nil
    }

    /// "Şarkı (feat. X) - Remastered 2011" → "Şarkı"
    static func cleanTitle(_ title: String) -> String {
        var result = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let dash = result.range(of: " - ") {
            result = String(result[..<dash.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - LRC biçimi

/// "[01:23.45] satır" biçimindeki zamanlı sözleri okur.
enum LRCParser {
    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset = 0.0
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTime(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let milliseconds = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = milliseconds / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let content = rest.trimmingCharacters(in: .whitespaces)
            for time in times {
                lines.append(LyricLine(time: time, text: content))
            }
        }
        return lines
            .map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }
            .sorted { $0.time < $1.time }
    }

    /// "mm:ss.xx" → saniye
    private static func parseTime(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }

    /// Şu an söylenen satırın sırası (ilk satırdan önceyse -1).
    static func currentIndex(in lines: [LyricLine], at position: Double) -> Int {
        var low = 0
        var high = lines.count - 1
        var found = -1
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].time <= position {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }
}

// MARK: - Görünüm

/// Büyük paneldeki söz alanı.
struct LyricsSection: View {
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var player: NowPlaying

    var body: some View {
        switch lyrics.state {
        case .synced(let lines):
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                // Satır, şarkıdan bir tık önce gelsin (göz sözü okurken ses yetişsin).
                let position = player.currentPosition(at: context.date) + 0.25
                SyncedLyricsView(lines: lines,
                                 current: LRCParser.currentIndex(in: lines, at: position),
                                 color: player.accent)
            }
        case .plain(let lines):
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { item in
                        Text(verbatim: item.element.isEmpty ? " " : item.element)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .instrumental:
            Text(verbatim: "♪  Enstrümantal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .none, .loading, .notFound:
            EmptyView()
        }
    }
}

/// Ortadaki satır şu an söylenen; şarkı ilerledikçe satırlar yukarı kayar.
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let current: Int
    let color: Color

    private let lineHeight: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if current < 0 {
                    // İlk satırdan önce (giriş müziği)
                    Text(verbatim: "♪")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(color)
                        .frame(width: geo.size.width, height: lineHeight, alignment: .leading)
                }
                ForEach(visibleIndices, id: \.self) { index in
                    let distance = index - current
                    Text(verbatim: lines[index].text.isEmpty ? "♪" : lines[index].text)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(distance == 0 ? Color.white : Color.white.opacity(distance < 0 ? 0.22 : 0.38))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .scaleEffect(distance == 0 ? 1 : 0.86, anchor: .leading)
                        .frame(width: geo.size.width, height: lineHeight, alignment: .leading)
                        .offset(y: CGFloat(distance) * lineHeight)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.28),
                .init(color: .black, location: 0.72),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: current)
    }

    /// Ekranda görünen satırlar: 2 önceki ... 3 sonraki.
    private var visibleIndices: [Int] {
        guard !lines.isEmpty else { return [] }
        let lower = max(0, current - 2)
        let upper = min(lines.count - 1, current + 3)
        return lower <= upper ? Array(lower...upper) : []
    }
}
