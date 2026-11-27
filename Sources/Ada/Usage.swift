import Foundation

/// Claude'un kullanım limitleri. Sadece terminaldeki Claude Code'un durum satırı (status line)
/// bu bilgiyi verir; masaüstü uygulamasında durum satırı olmadığı için orada görünmez.
struct ClaudeUsage: Equatable {
    var fiveHour: Double?      // 5 saatlik pencerenin yüzde kaçı doldu
    var fiveHourReset: Date?
    var week: Double?          // haftalık pencerenin yüzde kaçı doldu
    var weekReset: Date?
    var updated: Date

    init(fiveHour: Double?, fiveHourReset: Date?, week: Double?, weekReset: Date?, updated: Date = Date()) {
        self.fiveHour = fiveHour
        self.fiveHourReset = fiveHourReset
        self.week = week
        self.weekReset = weekReset
        self.updated = updated
    }

    /// "5 sa %42 · hafta %18". Sıfırlanmış (süresi geçmiş) pencereler gösterilmez.
    func text(at now: Date = Date()) -> String? {
        var parts: [String] = []
        if let fiveHour, Self.isFresh(reset: fiveHourReset, updated: updated, window: 5 * 3600, now: now) {
            parts.append("5 sa %\(Int(fiveHour.rounded()))")
        }
        if let week, Self.isFresh(reset: weekReset, updated: updated, window: 7 * 86_400, now: now) {
            parts.append("hafta %\(Int(week.rounded()))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func isFresh(reset: Date?, updated: Date, window: TimeInterval, now: Date) -> Bool {
        if let reset { return reset > now }
        return now.timeIntervalSince(updated) < window
    }

    // MARK: Ada'ya bildirimle taşıma

    var userInfo: [String: Any] {
        var info: [String: Any] = [:]
        if let fiveHour { info["five"] = fiveHour }
        if let fiveHourReset { info["fiveReset"] = fiveHourReset.timeIntervalSince1970 }
        if let week { info["week"] = week }
        if let weekReset { info["weekReset"] = weekReset.timeIntervalSince1970 }
        return info
    }

    init?(userInfo: [AnyHashable: Any]) {
        let five = (userInfo["five"] as? NSNumber)?.doubleValue
        let week = (userInfo["week"] as? NSNumber)?.doubleValue
        guard five != nil || week != nil else { return nil }
        self.init(fiveHour: five,
                  fiveHourReset: (userInfo["fiveReset"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                  week: week,
                  weekReset: (userInfo["weekReset"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
}

/// `Ada --statusline` → Claude Code durum satırı komutu.
/// stdin'den gelen JSON'daki `rate_limits` bilgisini Ada'ya iletir ve kısa bir durum satırı yazar.
enum UsageStatusLine {
    static let notificationName = Notification.Name("local.ada.usage")

    static func run() {
        var json: [String: Any] = [:]
        if isatty(STDIN_FILENO) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        let limits = json["rate_limits"] as? [String: Any] ?? [:]
        let five = limits["five_hour"] as? [String: Any]
        let week = limits["seven_day"] as? [String: Any]
        let usage = ClaudeUsage(fiveHour: number(five?["used_percentage"]), fiveHourReset: date(five?["resets_at"]),
                                week: number(week?["used_percentage"]), weekReset: date(week?["resets_at"]))

        if usage.fiveHour != nil || usage.week != nil {
            DistributedNotificationCenter.default().postNotificationName(
                notificationName, object: nil, userInfo: usage.userInfo, deliverImmediately: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        var parts: [String] = []
        if let model = (json["model"] as? [String: Any])?["display_name"] as? String, !model.isEmpty {
            parts.append(model)
        }
        if let text = usage.text() { parts.append(text) }
        print("🏝️ " + (parts.isEmpty ? "Ada" : parts.joined(separator: " · ")))
        fflush(stdout)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return (value as? String).flatMap(Double.init)
    }

    /// Sıfırlanma zamanı: saniye (epoch) ya da ISO 8601 yazı olabilir.
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds) // milisaniye de olabilir
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
