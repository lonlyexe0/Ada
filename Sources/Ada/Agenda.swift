import EventKit
import SwiftUI

/// Takvimdeki sıradaki etkinlikler (önümüzdeki 24 saat). Sadece okur, hiçbir şeyi değiştirmez.
/// İzin sadece sen paneldeki "Takvimi göster"e basınca istenir.
@MainActor
final class CalendarAgenda: ObservableObject {
    struct Event: Equatable, Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let color: Color
    }

    enum Access {
        case unknown   // henüz sorulmadı
        case granted
        case denied
    }

    @Published private(set) var upcoming: [Event] = []
    @Published private(set) var access: Access = .unknown

    private lazy var store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var started = false

    init(preview: Bool = false) {
        guard !preview else { return }
        updateAccess()
        if access == .granted { start() }
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    func requestAccess() {
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            updateAccess()
            AdaLog.write("takvim izni: \(granted ? "verildi" : "verilmedi")")
            if granted { start() }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Geçen etkinlikler düşsün diye 5 dakikada bir yenile
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard access == .granted else { return }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: 24, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: end, calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { event in
                Event(id: event.eventIdentifier ?? UUID().uuidString,
                      title: event.title ?? "Etkinlik",
                      start: event.startDate,
                      end: event.endDate,
                      color: Color(cgColor: event.calendar.cgColor))
            }
    }

    func loadPreview(_ on: Bool) {
        guard on else {
            access = .unknown
            upcoming = []
            return
        }
        access = .granted
        let start = Date().addingTimeInterval(25 * 60)
        upcoming = [Event(id: "demo", title: "Fizik dersi", start: start, end: start.addingTimeInterval(3600),
                          color: .blue)]
    }
}

/// Boştaki paneldeki takvim satırı.
struct AgendaLine: View {
    @ObservedObject var agenda: CalendarAgenda
    /// Her dakika değişir ki "25 dk sonra" güncel kalsın.
    let now: Date

    var body: some View {
        switch agenda.access {
        case .unknown:
            Button { agenda.requestAccess() } label: {
                Label { Text(verbatim: "Takvimi göster") } icon: { Image(systemName: "calendar") }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(PressScaleStyle())
        case .granted:
            if let event = agenda.upcoming.first {
                HStack(spacing: 5) {
                    Circle().fill(event.color).frame(width: 6, height: 6)
                    Text(verbatim: event.title)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(verbatim: "· " + Self.when(event, now: now))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 11, weight: .semibold))
            } else {
                Text(verbatim: "Bugün başka etkinlik yok")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        case .denied:
            EmptyView()
        }
    }

    /// "14:30 · 25 dk sonra" ya da "şu an"
    static func when(_ event: CalendarAgenda.Event, now: Date) -> String {
        if event.start <= now { return "şu an" }
        let time = clock.string(from: event.start)
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return "\(time) · \(max(1, minutes)) dk sonra" }
        return time
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
