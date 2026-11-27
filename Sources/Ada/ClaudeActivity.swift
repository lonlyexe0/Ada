import AppKit

/// Claude Code oturumlarının o anki durumu. Kancalardan gelen olaylarla güncellenir.
@MainActor
final class ClaudeActivity: ObservableObject {
    enum Phase: Equatable {
        case working  // Claude çalışıyor
        case waiting  // senin onayını bekliyor
    }

    struct Session: Equatable {
        var start: Date      // sen mesajı gönderdiğin an (sayaç buradan sayar)
        var lastEvent: Date
        var folder: String
        var phase: Phase
        var note: String     // onay bekliyorsa Claude Code'un bildirimi
    }

    struct Finished: Equatable {
        var folder: String
        var at: Date
    }

    static let bundleID = "com.anthropic.claudefordesktop"

    /// Oturum kimliği → durum (aynı anda birden fazla Claude penceresi olabilir).
    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var lastFinished: Finished?
    /// Claude bitirdi ama sen daha görmedin → çentiğin yanında ✓ durur.
    @Published private(set) var unseenDone = false
    /// Kullanım limitleri (sadece terminaldeki Claude Code'un durum satırından gelir).
    @Published private(set) var usage: ClaudeUsage?

    /// "5 sa %42 · hafta %18" (sıfırlanmış pencereler gösterilmez).
    var usageText: String? { usage?.text() }

    /// Gösterilecek oturum: önce onay bekleyen, yoksa en son hareket eden.
    var current: Session? {
        let waiting = sessions.values.filter { $0.phase == .waiting }
        let pool = waiting.isEmpty ? Array(sessions.values) : waiting
        return pool.max { $0.lastEvent < $1.lastEvent }
    }

    var isWaiting: Bool { sessions.values.contains { $0.phase == .waiting } }
    var isWorking: Bool { !sessions.isEmpty }
    /// Büyük panelde Claude satırı gösterilsin mi?
    var hasRow: Bool { isWorking || lastFinished != nil || usageText != nil }

    func updateUsage(_ usage: ClaudeUsage) {
        self.usage = usage
    }

    /// "Bash için onayını bekliyorum" gibi kısa açıklama.
    var waitingText: String {
        let note = current?.note ?? ""
        if let range = note.range(of: "permission to use ") {
            let tool = note[range.upperBound...]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            if !tool.isEmpty { return "\(tool) için onayını bekliyorum" }
        }
        return "Onayını bekliyorum"
    }

    func handle(_ kind: ClaudeEventKind, session id: String, folder: String, note: String) {
        let key = id.isEmpty ? "-" : id
        let now = Date()
        switch kind {
        case .start, .tool, .wait:
            if kind == .start, unseenDone { unseenDone = false } // yeni mesaj yazdın: görmüşsün
            var session = sessions[key]
                ?? Session(start: now, lastEvent: now, folder: folder, phase: .working, note: "")
            session.lastEvent = now
            session.phase = kind == .wait ? .waiting : .working
            session.note = kind == .wait ? note : ""
            if !folder.isEmpty { session.folder = folder }
            sessions[key] = session
        case .done:
            let finishedFolder = sessions[key]?.folder ?? folder
            sessions[key] = nil
            lastFinished = Finished(folder: finishedFolder, at: now)
            unseenDone = true
        }
    }

    /// Paneli açtın ya da Claude'a geçtin: ✓ kalkar.
    func markSeen() {
        if unseenDone { unseenDone = false }
    }

    /// Uzun süredir haber gelmeyen oturumları temizle (pencere kapanmış olabilir).
    func pruneStale(now: Date = Date()) {
        for (key, session) in sessions where now.timeIntervalSince(session.lastEvent) > 20 * 60 {
            sessions[key] = nil
        }
        if let finished = lastFinished, now.timeIntervalSince(finished.at) > 10 * 60 {
            lastFinished = nil
        }
    }

    /// Claude uygulamasını öne getir.
    func openClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Önizleme (snapshot)

    func loadPreview(_ phase: Phase?, finished: Bool = false, unseen: Bool = false, usage: Bool = false) {
        self.usage = usage ? ClaudeUsage(fiveHour: 42, fiveHourReset: nil, week: 18, weekReset: nil) : nil
        let now = Date()
        if let phase {
            sessions = ["preview": Session(start: now.addingTimeInterval(-83), lastEvent: now, folder: "Ada",
                                           phase: phase, note: "Claude needs your permission to use Bash")]
        } else {
            sessions = [:]
        }
        lastFinished = finished ? Finished(folder: "Ada", at: now.addingTimeInterval(-180)) : nil
        unseenDone = unseen
    }
}
