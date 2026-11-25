import Foundation

/// Mesajı kim gönderdi?
enum MessageSender: String {
    case user    // terminalden: ada "mesaj"
    case claude  // Claude Code işini bitirince (kanca)
}

/// Adada birkaç saniye görünen kısa mesaj.
struct IslandMessage: Equatable {
    let id = UUID()
    let text: String
    let sender: MessageSender
}

/// Claude Code kancalarından gelen olaylar.
enum ClaudeEventKind: String {
    case start  // sen mesaj gönderdin (UserPromptSubmit) → çalışıyor
    case tool   // bir araç bitti (PostToolUse) → çalışmaya devam
    case wait   // onayını bekliyor (Notification)
    case done   // cevabını bitirdi (Stop)
}

/// Başka programlardan (terminal, Claude Code) Ada'ya haber gönderme.
/// Sistem genelinde bir duyuru (distributed notification) yayınlar; çalışan Ada onu yakalar.
enum Messenger {
    static let notificationName = Notification.Name("local.ada.message")
    static let claudeNotificationName = Notification.Name("local.ada.claude")

    /// `Ada --say "mesaj"`
    static func post(_ text: String, from sender: MessageSender) {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: nil,
            userInfo: ["text": clean, "from": sender.rawValue],
            deliverImmediately: true)
        settle()
    }

    /// `Ada --claude` / `Ada --claude-event <tür>` → Claude Code kancalarından çağrılır.
    /// Kanca, stdin'den olay bilgisini (JSON) verir. Sadece oturum kimliği, klasör adı ve
    /// bildirim metni okunur; gönderdiğin mesajın içeriğine bakılmaz.
    static func postClaudeEvent(_ kind: ClaudeEventKind) {
        var session = ""
        var folder = ""
        var note = ""
        if isatty(STDIN_FILENO) == 0 { // terminalden elle çalıştırılınca beklemesin
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                session = json["session_id"] as? String ?? ""
                if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                    folder = URL(fileURLWithPath: cwd).lastPathComponent
                }
                if kind == .wait {
                    note = json["message"] as? String ?? ""
                    // İş bittikten sonra gelen "seni bekliyorum" hatırlatması onay isteği sayılmaz
                    let type = json["notification_type"] as? String ?? ""
                    if type == "idle_prompt" || note.lowercased().contains("waiting for your input") { return }
                }
            }
        }
        DistributedNotificationCenter.default().postNotificationName(
            claudeNotificationName, object: nil,
            userInfo: ["kind": kind.rawValue, "session": session, "folder": folder,
                       "note": String(note.prefix(160))],
            deliverImmediately: true)
        settle()
    }

    /// Duyurunun çıkması için çok kısa bekle, sonra kapan.
    private static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

/// ~/Library/Logs/Ada.log — mesajlar geldi mi diye bakmak için kısa kayıt.
/// (Mesajın kendisini değil, sadece türünü / kimden geldiğini yazar.)
enum AdaLog {
    static func write(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ada.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size < 200_000, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url) // yoksa oluştur, çok büyüdüyse baştan başla
        }
    }
}
