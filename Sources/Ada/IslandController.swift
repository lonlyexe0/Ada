import AppKit
import SwiftUI

// MARK: - Durum

/// Kısa süreliğine kendiliğinden açılan haller.
enum Peek: Equatable {
    case charging  // şarj takıldı
    case volume    // ses değişti
}

/// Açık panelde iki parmakla kaydırma yönü.
enum SwipeDirection: Equatable {
    case previous  // sola → önceki şarkı
    case next      // sağa → sonraki şarkı
}

/// Büyük paneldeki sekmeler.
enum PanelTab: String, CaseIterable {
    case home       // müzik ya da saat + Claude
    case shelf      // dosya rafı
    case clipboard  // pano geçmişi
}

/// Adanın o anki hali.
enum IslandMode: String, CaseIterable {
    case closed            // sadece çentik (siyah üstüne siyah, görünmez)
    case music             // müzik çalıyor: kapak + ekolayzer, altta şarkı adı
    case claude            // Claude çalışıyor: solda mini maskot, sağda geçen süre
    case claudeWaiting     // Claude onayını bekliyor: maskot "?" ile çıkar
    case claudeDone        // Claude bitirdi ama sen görmedin: mini maskot + ✓ (sen bakana kadar)
    case claudePermission  // Claude izin istiyor: çentikten "İzin ver / Reddet"
    case message           // terminalden / Claude'dan mesaj: altta yazı + yanan çizgi
    case charging          // şarj takıldı
    case volume            // ses tuşları: hoparlör + seviye
    case expanded          // fare üstünde: büyük panel
}

/// Çentiğin ölçüleri (point cinsinden).
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool
}

@MainActor
final class IslandState: ObservableObject {
    @Published var hovered = false
    @Published var peek: Peek?
    @Published var notch = NotchMetrics(width: 190, height: 32, hasNotch: false)
    /// Test/snapshot için belli bir hali zorla göstermek.
    @Published var forcedMode: IslandMode?
    /// İki parmakla kaydırma: -1 (önceki) ... 0 ... 1 (sonraki). ±1'i geçip bırakınca şarkı değişir.
    @Published var swipeProgress: CGFloat = 0
    /// Kaydırma tamamlanınca ilgili buton kısa süre parlar.
    @Published var swipeFlash: SwipeDirection?
    /// Terminalden ya da Claude'dan gelen kısa mesaj (birkaç saniye görünür).
    @Published var message: IslandMessage?
    /// Son mesajı kim gönderdi (çizgi kaybolurken rengi değişmesin diye).
    @Published var lastSender: MessageSender = .user
    /// Claude işini bitirince / onay beklerken maskot çıksın mı? (menüden açılıp kapatılır)
    @Published var mascotEnabled: Bool = UserDefaults.standard.object(forKey: "mascotEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mascotEnabled, forKey: "mascotEnabled") }
    }
    /// Büyük panelde açık sekme.
    @Published var tab: PanelTab = .home
    /// Şu an bir dosya sürükleniyor mu? (çentiğe gelince raf açılsın)
    @Published var fileDragActive = false
}

// MARK: - Boyutlar

struct IslandLayout {
    let notch: NotchMetrics
    /// Büyük panelde şarkı sözü alanı var mı?
    var showsLyrics = false
    /// Büyük panelde Claude satırı var mı?
    var showsClaude = false
    /// Büyük panelde hangi sekme açık?
    var tab: PanelTab = .home

    /// Müzik çalarken çentiğin altındaki şarkı adı satırı.
    static let titleLineHeight: CGFloat = 26
    /// Büyük paneldeki söz alanı (+ boşluk).
    static let lyricsHeight: CGFloat = 86
    /// Büyük paneldeki Claude satırı (+ boşluk).
    static let claudeRowHeight: CGFloat = 36
    /// İzin kartının çentik altındaki kısmı.
    static let permissionHeight: CGFloat = 120
    /// Raf ve pano sekmelerinin çentik altındaki kısmı.
    static let shelfHeight: CGFloat = 118
    static let clipboardHeight: CGFloat = 198

    /// Çentiğin iki yanında kapak / ekolayzer için açılan alan.
    var ear: CGFloat { max(46, notch.height + 10) }

    var expandedSize: CGSize {
        let width = max(notch.width + 300, 500)
        switch tab {
        case .home:
            return CGSize(width: width,
                          height: notch.height + 112
                              + (showsLyrics ? Self.lyricsHeight : 0)
                              + (showsClaude ? Self.claudeRowHeight : 0))
        case .shelf:
            return CGSize(width: width, height: notch.height + Self.shelfHeight)
        case .clipboard:
            return CGSize(width: width, height: notch.height + Self.clipboardHeight)
        }
    }

    /// En büyük hal: pencere bu kadar (+ gölge payı) olur ki her sekme ve izin kartı sığsın.
    static func largestSize(notch: NotchMetrics) -> CGSize {
        let sizes = PanelTab.allCases.map {
            IslandLayout(notch: notch, showsLyrics: true, showsClaude: true, tab: $0).expandedSize
        } + [IslandLayout(notch: notch).size(for: .claudePermission)]
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    }

    func size(for mode: IslandMode) -> CGSize {
        switch mode {
        case .closed:
            return CGSize(width: notch.width, height: notch.height)
        case .music:
            return CGSize(width: notch.width + ear * 2 + 60, height: notch.height + Self.titleLineHeight)
        case .claude, .claudeDone:
            return CGSize(width: notch.width + ear * 2 + 16, height: notch.height)
        case .message, .claudeWaiting:
            return CGSize(width: notch.width + ear * 2 + 100, height: notch.height + Self.titleLineHeight)
        case .claudePermission:
            return CGSize(width: max(notch.width + ear * 2 + 180, 460), height: notch.height + Self.permissionHeight)
        case .charging:
            return CGSize(width: notch.width + 220, height: notch.height)
        case .volume:
            return CGSize(width: notch.width + ear * 2 + 50, height: notch.height)
        case .expanded:
            return expandedSize
        }
    }

    /// top: çentiğin menü çubuğuna kıvrıldığı içbükey köşe, bottom: alt köşelerin yuvarlaklığı.
    func radii(for mode: IslandMode) -> (top: CGFloat, bottom: CGFloat) {
        switch mode {
        case .closed:                                    return (6, 10)
        case .charging, .claude, .claudeDone, .volume:   return (6, 12)
        case .music, .message, .claudeWaiting:           return (8, 18)
        case .claudePermission:                          return (10, 24)
        case .expanded:                                  return (12, 32)
        }
    }

    /// Öncelik: Claude izin istiyor > fare üstünde > mesaj > Claude onay bekliyor > ses > şarj > müzik
    /// > Claude çalışıyor > Claude bitirdi (görülmedi) > kapalı.
    /// (İzin kartı fare üstündeyken de kalır ki butonlara basabilesin.)
    static func mode(hovered: Bool, peek: Peek?, permissionPending: Bool, hasMessage: Bool, claudeWaiting: Bool,
                     claudeWorking: Bool, claudeUnseen: Bool, hasTrack: Bool, isPlaying: Bool) -> IslandMode {
        if permissionPending { return .claudePermission }
        if hovered { return .expanded }
        if hasMessage { return .message }
        if claudeWaiting { return .claudeWaiting }
        if peek == .volume { return .volume }
        if peek == .charging { return .charging }
        if hasTrack, isPlaying { return .music }
        if claudeWorking { return .claude }
        if claudeUnseen { return .claudeDone }
        return .closed
    }
}

/// Görünüm ve kontrolcü aynı hesabı yapsın diye.
extension IslandLayout {
    @MainActor
    init(state: IslandState, player: NowPlaying, lyrics: LyricsStore, claude: ClaudeActivity) {
        let home = state.tab == .home
        self.init(notch: state.notch,
                  showsLyrics: home && player.track != nil && !player.musicIdle && lyrics.hasContent,
                  showsClaude: home && claude.hasRow,
                  tab: state.tab)
    }

    @MainActor
    static func mode(state: IslandState, player: NowPlaying, claude: ClaudeActivity,
                     permissions: PermissionCenter) -> IslandMode {
        state.forcedMode ?? mode(
            hovered: state.hovered, peek: state.peek, permissionPending: permissions.isPending,
            hasMessage: state.message != nil, claudeWaiting: claude.isWaiting, claudeWorking: claude.isWorking,
            claudeUnseen: claude.unseenDone, hasTrack: player.track != nil, isPlaying: player.isPlaying)
    }
}

// MARK: - Kontrolcü

/// Pencereyi çentiğin üstüne yerleştirir, fareyi takip eder, kısa bildirimleri (peek) yönetir.
@MainActor
final class IslandController {
    let state: IslandState
    let player: NowPlaying
    let battery: BatteryMonitor
    let lyrics: LyricsStore
    let claude: ClaudeActivity
    let permissions: PermissionCenter
    let shelf: FileShelf
    let clipboard: ClipboardHistory
    let agenda: CalendarAgenda
    let volume: VolumeMonitor

    private let panel: IslandPanel
    private let permissionServer = PermissionServer()
    private var screen: NSScreen?
    private var observers: [NSObjectProtocol] = []

    private var insideSince: Date?
    private var outsideSince: Date?
    private var peekToken = 0
    private var messageToken = 0

    // İki parmakla kaydırma
    private var scrollMonitor: Any?
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private var swipeIsHorizontal = false
    private var swipeArmed = false
    private var swipeFlashToken = 0
    private let swipeThreshold: CGFloat = 80  // bu kadar kaydırıp bırakınca şarkı değişir

    // Dosya sürükleme (çentiğe dosya getirince raf açılsın)
    private var mouseDownMonitor: Any?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragBaseline: Int?

    private let openDelay: TimeInterval = 0.12   // üstüne gelince açılmadan önce bekleme
    private let closeDelay: TimeInterval = 0.3   // çıkınca kapanmadan önce bekleme

    init() {
        state = IslandState()
        player = NowPlaying()
        battery = BatteryMonitor()
        lyrics = LyricsStore()
        claude = ClaudeActivity()
        permissions = PermissionCenter()
        shelf = FileShelf()
        clipboard = ClipboardHistory()
        agenda = CalendarAgenda()
        volume = VolumeMonitor()
        panel = IslandPanel(contentRect: .zero)

        let root = IslandRootView(state: state, player: player, battery: battery, lyrics: lyrics, claude: claude,
                                  permissions: permissions, shelf: shelf, clipboard: clipboard, agenda: agenda,
                                  volume: volume)
        let host = IslandHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        placeWindow()
        panel.orderFrontRegardless()

        // Şarkı değişince sözleri getir.
        player.trackDidChange = { [weak self] track in self?.lyrics.load(for: track) }
        battery.onPluggedIn = { [weak self] in self?.showPeek(.charging, seconds: 3) }
        volume.onChange = { [weak self] in self?.showPeek(.volume, seconds: 1.6) }

        // Claude'un izin istekleri (PermissionRequest kancası → yerel soket)
        permissionServer.onRequest = { [weak self] id, payload, reply in
            guard let self else {
                reply(.pass)
                return
            }
            self.handlePermission(id: id, payload: payload, reply: reply)
        }
        permissionServer.onCancel = { [weak self] id in self?.permissions.cancel(id) }
        permissionServer.start()

        // Ekran değişirse (harici monitör vs.) yeniden yerleştir.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeWindow() }
        })

        // Terminalden gelen mesajlar (ada "mesaj")
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Messenger.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            let text = note.userInfo?["text"] as? String ?? ""
            let sender = MessageSender(rawValue: note.userInfo?["from"] as? String ?? "") ?? .user
            MainActor.assumeIsolated { self?.showMessage(text, from: sender) }
        })

        // Claude Code kancalarından gelen olaylar (başladı / araç bitti / onay bekliyor / bitti)
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Messenger.claudeNotificationName, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let kind = ClaudeEventKind(rawValue: info["kind"] as? String ?? "")
            let session = info["session"] as? String ?? ""
            let folder = info["folder"] as? String ?? ""
            let text = info["note"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let kind else { return }
                self?.handleClaude(kind, session: session, folder: folder, note: text)
            }
        })

        // Claude kullanım limitleri (terminaldeki Claude Code'un durum satırından)
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: UsageStatusLine.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            let usage = ClaudeUsage(userInfo: note.userInfo ?? [:])
            MainActor.assumeIsolated {
                guard let usage else { return }
                self?.claude.updateUsage(usage)
                AdaLog.write("kullanım güncellendi")
            }
        })

        // Claude uygulamasına geçince "bitirdi" işareti (✓) görülmüş sayılır.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                guard bundleID == ClaudeActivity.bundleID else { return }
                self?.claude.markSeen()
            }
        })

        startMouseTracking()
        startSwipeMonitor()
        startDragWatch()
        startHousekeeping()
        player.start()
    }

    // MARK: Yerleşim

    private func placeWindow() {
        let screen = Self.targetScreen()
        self.screen = screen
        guard let screen else { return }
        state.notch = Self.metrics(for: screen)
        panel.setFrame(Self.windowFrame(on: screen, notch: state.notch), display: true)
    }

    /// Pencere, en büyük hal + gölge payı kadar; ekranın en üst ortasında.
    static func windowFrame(on screen: NSScreen, notch: NotchMetrics) -> NSRect {
        let size = IslandLayout.largestSize(notch: notch)
        let width = size.width + 80
        let height = size.height + 50
        return NSRect(x: (screen.frame.midX - width / 2).rounded(),
                      y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    /// Çentikli ekranı tercih et (MacBook'un kendi ekranı).
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // Çentiğin solu ve sağı menü çubuğu; aradaki boşluk çentiğin kendisi.
            return NotchMetrics(width: screen.frame.width - left.width - right.width, height: top, hasNotch: true)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchMetrics(width: 190, height: max(menuBar, 24), hasNotch: false)
    }

    // MARK: Fare

    private func startMouseTracking() {
        Task { [weak self] in
            while let self {
                let wait = self.trackMouse()
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private var currentLayout: IslandLayout {
        IslandLayout(state: state, player: player, lyrics: lyrics, claude: claude)
    }

    private var currentMode: IslandMode {
        IslandLayout.mode(state: state, player: player, claude: claude, permissions: permissions)
    }

    /// Fare adanın üstünde mi? Bir sonraki kontrole kadar beklenecek süreyi döndürür.
    private func trackMouse() -> TimeInterval {
        guard let screen else { return 0.5 }
        let mouse = NSEvent.mouseLocation
        updateFileDrag()
        let mode = currentMode
        let size = currentLayout.size(for: mode)
        // Dosya sürüklerken çentiği tutturmak kolay olsun diye alan biraz büyür.
        let margin: CGFloat = mode == .expanded ? -12 : (state.fileDragActive ? -30 : -6)
        let rect = NSRect(x: screen.frame.midX - size.width / 2,
                          y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
            .insetBy(dx: margin, dy: margin)
        let inside = rect.contains(mouse)
        let now = Date()

        if inside {
            outsideSince = nil
            let since = insideSince ?? now
            insideSince = since
            if !state.hovered, now.timeIntervalSince(since) >= openDelay {
                state.tab = state.fileDragActive ? .shelf : .home
                state.hovered = true
                state.peek = nil
                claude.markSeen() // paneli açtın: "bitirdi" işaretini gördün
            }
        } else {
            insideSince = nil
            if state.hovered {
                let since = outsideSince ?? now
                outsideSince = since
                if now.timeIntervalSince(since) >= closeDelay {
                    state.hovered = false
                    outsideSince = nil
                }
            }
        }

        // Panel açıkken dosya sürükleniyorsa rafı göster.
        if state.hovered, state.fileDragActive, state.tab != .shelf {
            state.tab = .shelf
        }

        // Sadece fare açık adanın üstündeyken tıklamaları al; yoksa tıklamalar alttaki pencerelere geçsin.
        let acceptClicks = state.hovered && inside
        if panel.ignoresMouseEvents == acceptClicks {
            panel.ignoresMouseEvents = !acceptClicks
        }

        // Fare uzaktaysa daha seyrek bak (pil dostu).
        let nearTop = mouse.y > screen.frame.maxY - 300 && abs(mouse.x - screen.frame.midX) < 400
        return (nearTop || state.hovered) ? 1.0 / 40 : 0.12
    }

    // MARK: Dosya sürükleme

    /// Fare basılınca sürükleme panosunun sayacını not al. Basılıyken sayaç değişir ve içinde
    /// dosya varsa (Finder'dan vs.) bir dosya sürükleniyordur. (Panonun içeriği okunmaz.)
    private func startDragWatch() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragBaseline = self.dragPasteboard.changeCount
            }
        }
    }

    private func updateFileDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            if state.fileDragActive { state.fileDragActive = false }
            return
        }
        guard !state.fileDragActive, let baseline = dragBaseline,
              dragPasteboard.changeCount != baseline else { return }
        dragBaseline = nil // bu sürükleme için bir kez bakmak yeter
        if dragPasteboard.types?.contains(.fileURL) == true {
            state.fileDragActive = true
        }
    }

    // MARK: Claude

    private func handleClaude(_ kind: ClaudeEventKind, session: String, folder: String, note: String) {
        AdaLog.write("claude olayı: \(kind.rawValue)")
        claude.handle(kind, session: session, folder: folder, note: note)
        switch kind {
        case .wait:
            state.lastSender = .claude // çizgi turuncu yansın
        case .done:
            showMessage(folder.isEmpty ? "İşim bitti!" : "İşim bitti · \(folder)", from: .claude)
            if state.hovered { claude.markSeen() } // panel zaten açıksa görüyorsun
        case .start, .tool:
            break
        }
    }

    /// Claude izin istedi. Karar sadece çentikteki butonlarla verilir.
    private func handlePermission(id: Int, payload: PermissionPayload,
                                  reply: @escaping @Sendable (PermissionReply) -> Void) {
        // Claude penceresi zaten öndeyse orada cevaplarsın: hemen Claude'un kendi penceresine bırak.
        if payload.fromDesktop,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeActivity.bundleID {
            AdaLog.write("izin isteği: Claude önde, Claude'un kendi penceresine bırakıldı")
            reply(.pass)
            return
        }
        state.lastSender = .claude
        permissions.enqueue(id: id, payload: payload, reply: reply)
    }

    /// Dakikada bir: uzun süredir haber gelmeyen Claude oturumlarını ve silinen raf dosyalarını temizle.
    private func startHousekeeping() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                self.claude.pruneStale()
                self.shelf.pruneMissing()
            }
        }
    }

    // MARK: Mesajlar

    private func showMessage(_ text: String, from sender: MessageSender) {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !clean.isEmpty else { return }
        messageToken += 1
        let token = messageToken
        state.lastSender = sender
        state.message = IslandMessage(text: clean, sender: sender)
        AdaLog.write("mesaj gösterildi: \(sender.rawValue), \(clean.count) karakter")
        // Claude'un "bitti" bildirimi 10 sn kalır (sonra çentiğin yanında ✓ olarak bekler)
        let seconds = sender == .claude ? 10 : min(10, 4.5 + Double(clean.count) * 0.05)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.messageToken == token else { return }
            self.state.message = nil
        }
    }

    // MARK: İki parmakla kaydırma (sonraki / önceki şarkı)

    private func startSwipeMonitor() {
        // Panel açıkken trackpad kaydırmaları bizim pencereye gelir; burada yakalıyoruz.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// true dönerse olayı biz kullandık (alttaki görünüme gitmesin).
    private func handleScroll(_ event: NSEvent) -> Bool {
        // Sadece ana sekmede ve müzik varken (raf / pano sekmelerinde kaydırma o listelere gitsin)
        guard state.hovered, state.tab == .home, player.track != nil, !player.musicIdle,
              event.hasPreciseScrollingDeltas
        else { return false }

        // Parmaklar kalktıktan sonra gelen "kayma devam ediyor" olayları
        if !event.momentumPhase.isEmpty { return swipeIsHorizontal }

        if event.phase.contains(.began) {
            swipeX = 0
            swipeY = 0
            swipeIsHorizontal = false
            swipeArmed = false
        }

        if event.phase.contains(.began) || event.phase.contains(.changed) {
            // Parmakların gerçek yönü (sağa = +), "doğal kaydırma" ayarından bağımsız.
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            swipeX += dx
            swipeY += abs(event.scrollingDeltaY)
            // Yatay mı? (yukarı-aşağı kaydırmaları bozmayalım)
            if !swipeIsHorizontal, abs(swipeX) > 10, abs(swipeX) > swipeY * 1.4 {
                swipeIsHorizontal = true
            }
            guard swipeIsHorizontal else { return false }

            state.swipeProgress = max(-1.25, min(1.25, swipeX / swipeThreshold))
            let armed = abs(swipeX) >= swipeThreshold
            if armed != swipeArmed {
                swipeArmed = armed
                // Eşik geçilince trackpad'den hafif bir "tık" hissi
                if armed {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            return true
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let wasHorizontal = swipeIsHorizontal
            if wasHorizontal, swipeArmed, event.phase.contains(.ended) {
                performSwipe(swipeX > 0 ? .next : .previous)
            }
            swipeArmed = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                state.swipeProgress = 0
            }
            return wasHorizontal
        }

        return swipeIsHorizontal
    }

    private func performSwipe(_ direction: SwipeDirection) {
        switch direction {
        case .next: player.next()
        case .previous: player.previous()
        }
        swipeFlashToken += 1
        let token = swipeFlashToken
        state.swipeFlash = direction
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, self.swipeFlashToken == token else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.state.swipeFlash = nil
            }
        }
    }

    // MARK: Kısa bildirimler

    private func showPeek(_ peek: Peek, seconds: Double) {
        guard !state.hovered else { return }
        peekToken += 1
        let token = peekToken
        state.peek = peek
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.peekToken == token else { return }
            self.state.peek = nil
        }
    }
}

// MARK: - Pencere

/// Kenarlıksız, şeffaf, menü çubuğunun da üstünde duran panel. Odağı çalmaz.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // macOS pencereyi menü çubuğunun altına itmesin.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// İlk tıklamada da butonlar çalışsın (pencere odakta olmasa bile).
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
