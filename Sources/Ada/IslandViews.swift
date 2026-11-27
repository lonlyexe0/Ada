import SwiftUI

/// Adanın kendisi: çentik şeklinde siyah alan + o anki hale göre içerik.
struct IslandRootView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var player: NowPlaying
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var claude: ClaudeActivity
    @ObservedObject var permissions: PermissionCenter
    let shelf: FileShelf
    let clipboard: ClipboardHistory
    let agenda: CalendarAgenda
    let volume: VolumeMonitor

    /// Claude'la ilgili her şeyin rengi (maskotla aynı turuncu).
    static let claudeOrange = MascotColors.orangeSwiftUI

    var body: some View {
        let layout = IslandLayout(state: state, player: player, lyrics: lyrics, claude: claude)
        let mode = IslandLayout.mode(state: state, player: player, claude: claude, permissions: permissions)
        let size = layout.size(for: mode)
        let radius = layout.radii(for: mode)
        let shape = NotchShape(topRadius: radius.top, bottomRadius: radius.bottom)
        let claudeDone = mode == .message && state.message?.sender == .claude
        // Claude senden bir şey bekliyor (izin ya da onay): maskot "?" ile çıkar, çizgi turuncu yanar.
        let asking = mode == .claudeWaiting || mode == .claudePermission
        let lineColor = asking || (state.message?.sender ?? state.lastSender) == .claude
            ? Self.claudeOrange : Color.white

        ZStack(alignment: .top) {
            // 1) Claude'un maskotu: iş bitince ya da senden bir şey beklerken adanın arkasından aşağı sarkar
            mascotLayer(visible: state.mascotEnabled && (claudeDone || asking), asking: asking)
                .offset(y: size.height - 3)

            // 2) Adanın kendisi
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                content(for: mode, size: size)
            }
            .frame(width: size.width + radius.top * 2, height: size.height)
            .clipShape(shape)
            .shadow(color: .black.opacity(mode == .expanded || mode == .claudePermission ? 0.45 : 0),
                    radius: 14, y: 6)
            .opacity(mode == .closed && !state.notch.hasNotch ? 0 : 1)

            // 3) Alt kenarda yanan ince çizgi (Claude: turuncu, terminal: beyaz)
            noticeLine(active: mode == .message || asking, width: size.width, color: lineColor)
                .offset(y: size.height - 1.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: mode)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: size)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func mascotLayer(visible: Bool, asking: Bool) -> some View {
        ZStack {
            if visible {
                MascotView(asking: asking)
                    // Çıkarken adanın arkasından aşağı iner, giderken yukarı saklanır.
                    // (ada aynı anda küçüldüğü için tamamen saklanacak kadar yukarı çık)
                    .transition(.asymmetric(insertion: .offset(y: -66), removal: .offset(y: -66)))
            }
        }
        .frame(width: MascotStyle.big.size.width, height: MascotStyle.big.size.height)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: visible)
    }

    private func noticeLine(active: Bool, width: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: active ? min(width * 0.25, 90) : 0, height: 3)
            .shadow(color: color.opacity(0.9), radius: 4)
            .shadow(color: color.opacity(0.5), radius: 10)
            .opacity(active ? 1 : 0)
    }

    @ViewBuilder
    private func content(for mode: IslandMode, size: CGSize) -> some View {
        let notch = state.notch
        let fromClaude = state.message?.sender == .claude
        switch mode {
        case .closed:
            Color.clear.frame(width: size.width, height: size.height)
        case .music:
            VStack(spacing: 0) {
                CompactMusicRow(player: player, notch: notch, width: size.width,
                                claudeSince: claude.isWorking ? claude.current?.start : nil,
                                claudeDone: claude.unseenDone)
                TitleLine(track: player.track)
                    .frame(width: size.width, height: size.height - notch.height)
            }
            .transition(Self.fade)
        case .claude:
            ClaudeCompactRow(claude: claude, notch: notch, width: size.width)
                .transition(Self.fade)
        case .claudeDone:
            ClaudeDoneRow(notch: notch, width: size.width)
                .transition(Self.fade)
        case .claudeWaiting:
            MessageRow(icon: "hand.raised.fill", iconColor: Self.claudeOrange, label: "Claude",
                       text: claude.waitingText, notch: notch, width: size.width, height: size.height)
                .transition(Self.fade)
        case .claudePermission:
            PermissionCard(permissions: permissions, notch: notch, width: size.width, height: size.height,
                           onAnswer: answerPermission)
                .transition(Self.fade)
        case .message:
            MessageRow(icon: fromClaude ? "sparkle" : "terminal.fill",
                       iconColor: fromClaude ? Self.claudeOrange : .white,
                       label: fromClaude ? "Claude" : "Terminal",
                       text: state.message?.text ?? "", notch: notch, width: size.width, height: size.height)
                .transition(Self.fade)
        case .charging:
            ChargingRow(battery: battery, notch: notch, width: size.width)
                .transition(Self.fade)
        case .volume:
            VolumeRow(volume: volume, notch: notch, width: size.width)
                .transition(Self.fade)
        case .expanded:
            ExpandedView(state: state, player: player, battery: battery, lyrics: lyrics, claude: claude,
                         shelf: shelf, clipboard: clipboard, agenda: agenda, notch: notch)
                .frame(width: size.width, height: size.height, alignment: .top)
                .transition(Self.fade)
        }
    }

    /// İzin kartındaki butonlar. Cevaptan sonra kart kapanır (fare hâlâ üstündeyse açık panele dönmesin).
    private func answerPermission(_ reply: PermissionReply) {
        let fromDesktop = permissions.current?.fromDesktop ?? false
        permissions.answer(reply)
        if reply == .pass, fromDesktop { claude.openClaude() }
        state.hovered = false
    }

    private static var fade: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.88, anchor: .top))
    }
}

// MARK: - Küçük haller

/// Müzik çalarken: solda kapak, sağda ekolayzer (Claude çalışıyorsa onun sayacı).
struct CompactMusicRow: View {
    @ObservedObject var player: NowPlaying
    let notch: NotchMetrics
    let width: CGFloat
    var claudeSince: Date?
    var claudeDone = false

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: player.artwork, size: min(22, notch.height - 10), corner: 6)
                .padding(.leading, 16)
            Spacer(minLength: notch.width)
            if let claudeSince {
                ClaudeTimer(since: claudeSince)
                    .padding(.trailing, 16)
            } else if claudeDone {
                ClaudeCheck()
                    .padding(.trailing, 18)
            } else {
                EqualizerView(color: player.accent, isPlaying: player.isPlaying)
                    .frame(width: 18, height: min(14, notch.height - 16))
                    .padding(.trailing, 18)
            }
        }
        .frame(width: width, height: notch.height)
    }
}

/// Claude çalışırken: solda mini maskot (bacaklarını oynatır), sağda geçen süre.
struct ClaudeCompactRow: View {
    @ObservedObject var claude: ClaudeActivity
    let notch: NotchMetrics
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            MascotView(style: .mini)
                .padding(.leading, 14)
            Spacer(minLength: notch.width)
            ClaudeTimer(since: claude.current?.start)
                .padding(.trailing, 16)
        }
        .frame(width: width, height: notch.height)
    }
}

/// Claude bitirdi ama sen görmedin: solda duran mini maskot, sağda ✓ (sen bakana kadar kalır).
struct ClaudeDoneRow: View {
    let notch: NotchMetrics
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            MascotView(style: .mini, still: true)
                .padding(.leading, 14)
            Spacer(minLength: notch.width)
            ClaudeCheck()
                .padding(.trailing, 18)
        }
        .frame(width: width, height: notch.height)
    }
}

/// Turuncu ✓
struct ClaudeCheck: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(IslandRootView.claudeOrange)
    }
}

/// Geçen süre ("1:23"), kendiliğinden ilerler.
struct ClaudeTimer: View {
    let since: Date?

    var body: some View {
        if let since {
            Text(since, style: .timer)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(IslandRootView.claudeOrange)
        }
    }
}

/// Claude izin istiyor: ne yapmak istediği + Reddet / Claude'da aç / İzin ver.
/// Komutun tamamı sığmadıysa "İzin ver" çıkmaz; Claude'da bakman gerekir.
struct PermissionCard: View {
    @ObservedObject var permissions: PermissionCenter
    let notch: NotchMetrics
    let width: CGFloat
    let height: CGFloat
    let onAnswer: (PermissionReply) -> Void

    var body: some View {
        if let prompt = permissions.current {
            VStack(spacing: 0) {
                // Çentiğin iki yanı: kilit + geri sayım
                HStack(spacing: 0) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IslandRootView.claudeOrange)
                        .padding(.leading, 20)
                    Spacer(minLength: notch.width)
                    Text(timerInterval: prompt.arrived...prompt.deadline, countsDown: true)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.trailing, 20)
                }
                .frame(height: notch.height)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Text(verbatim: "\(prompt.toolName) için izin istiyor")
                            .foregroundStyle(IslandRootView.claudeOrange)
                        if !prompt.folder.isEmpty {
                            Text(verbatim: "· \(prompt.folder)")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                    Text(verbatim: prompt.detail.isEmpty ? "(ayrıntı yok)" : prompt.detail)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: 41, alignment: .topLeading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08)))

                    HStack(spacing: 8) {
                        CardButton(title: "Reddet", symbol: "xmark", fill: Color.white.opacity(0.14)) {
                            onAnswer(.deny)
                        }
                        Spacer(minLength: 4)
                        if !prompt.complete {
                            Text(verbatim: "Tamamı sığmadı")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        CardButton(title: prompt.fromDesktop ? "Claude'da aç" : "Terminalde cevapla",
                                   symbol: "arrow.up.forward.app", fill: Color.white.opacity(0.14)) {
                            onAnswer(.pass)
                        }
                        if prompt.complete {
                            CardButton(title: "İzin ver", symbol: "checkmark", fill: IslandRootView.claudeOrange) {
                                onAnswer(.allow)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
            .frame(width: width, height: height, alignment: .top)
        }
    }
}

/// İzin kartındaki buton.
struct CardButton: View {
    let title: String
    let symbol: String
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                Text(verbatim: title)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Çentiğin hemen altındaki "şarkı · sanatçı" satırı.
/// Şarkı değişince eskisi yukarı kayıp gider, yenisi aşağıdan gelir.
struct TitleLine: View {
    let track: Track?

    var body: some View {
        ZStack {
            SongLine(track: track)
                .id(track?.id ?? "")
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)))
        }
        .clipped()
        .animation(.easeInOut(duration: 0.35), value: track?.id)
    }
}

struct SongLine: View {
    let track: Track?

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: track?.title ?? "")
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .layoutPriority(1)
            if let artist = track?.artist, !artist.isEmpty {
                Text(verbatim: artist)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}

/// Mesaj / bekleme: çentiğin solunda simge, sağında kimden geldiği, altında yazı.
struct MessageRow: View {
    let icon: String
    let iconColor: Color
    let label: String
    let text: String
    let notch: NotchMetrics
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(iconColor)
                    .padding(.leading, 18)
                Spacer(minLength: notch.width)
                Text(verbatim: label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.trailing, 18)
            }
            .frame(height: notch.height)
            Text(verbatim: text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
                .frame(width: width, height: max(0, height - notch.height))
        }
        .frame(width: width, height: height)
    }
}

/// Şarj takılınca: solda "Şarj oluyor", sağda yüzde + pil.
struct ChargingRow: View {
    @ObservedObject var battery: BatteryMonitor
    let notch: NotchMetrics
    let width: CGFloat

    var body: some View {
        let ear = max(0, (width - notch.width) / 2)
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                Text(verbatim: battery.level >= 100 ? "Dolu" : "Şarj oluyor").foregroundStyle(.white)
            }
            .frame(width: ear)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(verbatim: "%\(battery.level)").monospacedDigit().foregroundStyle(.green)
                BatteryGlyph(level: battery.level, charging: true)
            }
            .frame(width: ear)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(width: width, height: notch.height)
    }
}

// MARK: - Büyük panel

/// Fare üstündeyken açılan panel. Üstte sekmeler: ana sayfa, raf, pano.
struct ExpandedView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var player: NowPlaying
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var claude: ClaudeActivity
    @ObservedObject var shelf: FileShelf
    let clipboard: ClipboardHistory
    let agenda: CalendarAgenda
    let notch: NotchMetrics

    var body: some View {
        VStack(spacing: 0) {
            topBar.frame(height: notch.height)
            Group {
                switch state.tab {
                case .home:
                    home
                case .shelf:
                    ShelfView(shelf: shelf)
                case .clipboard:
                    ClipboardView(clipboard: clipboard)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            if claude.hasRow {
                ClaudeRow(claude: claude)
                    .padding(.horizontal, 18)
                    .frame(height: IslandLayout.claudeRowHeight, alignment: .top)
            }
            Group {
                // Müzik 2 dk'dır duraklatılmışsa normal panel (saat, tarih, takvim, "Son çalan")
                if let track = player.track, !player.musicIdle {
                    MusicPanel(player: player, lyrics: lyrics, track: track,
                               swipeProgress: state.swipeProgress, swipeFlash: state.swipeFlash)
                } else {
                    IdlePanel(player: player, agenda: agenda)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Üst şerit: solda sekmeler, sağda pil. Ortası kamera çentiği.
    private var topBar: some View {
        HStack(spacing: 4) {
            tabButton(.home, symbol: "house.fill")
            tabButton(.shelf, symbol: shelf.files.isEmpty ? "tray.fill" : "tray.full.fill")
            tabButton(.clipboard, symbol: "doc.on.clipboard.fill")
            Spacer()
            if battery.hasBattery {
                HStack(spacing: 5) {
                    Text(verbatim: "%\(battery.level)").monospacedDigit()
                    BatteryGlyph(level: battery.level, charging: battery.onAC)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.5))
        .padding(.leading, 18)
        .padding(.trailing, 24)
    }

    private func tabButton(_ tab: PanelTab, symbol: String) -> some View {
        let selected = state.tab == tab
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { state.tab = tab }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.4))
                .frame(width: 28, height: 20)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Panelin üstündeki Claude satırı. Tıklayınca Claude uygulaması öne gelir.
struct ClaudeRow: View {
    @ObservedObject var claude: ClaudeActivity

    var body: some View {
        Button { claude.openClaude() } label: {
            HStack(spacing: 10) {
                MascotView(style: .mini)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(claude.isWaiting ? IslandRootView.claudeOrange : Color.white)
                    Text(verbatim: subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if claude.isWorking, !claude.isWaiting {
                    ClaudeTimer(since: claude.current?.start)
                }
                Text(verbatim: "Aç")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(IslandRootView.claudeOrange.opacity(claude.isWaiting ? 0.9 : 0.35)))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var title: String {
        if claude.isWaiting { return claude.waitingText }
        if claude.isWorking { return "Claude çalışıyor" }
        if claude.lastFinished != nil { return "Claude işini bitirdi" }
        return "Claude kullanımı"
    }

    /// Klasör · ne zaman · kullanım limitleri ("5 sa %42 · hafta %18")
    private var subtitle: String {
        var parts: [String] = []
        if let session = claude.current {
            parts.append(session.folder.isEmpty ? "Claude Code" : session.folder)
        } else if let finished = claude.lastFinished {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "tr_TR")
            formatter.unitsStyle = .short
            let ago = formatter.localizedString(for: finished.at, relativeTo: Date())
            parts.append(finished.folder.isEmpty ? ago : "\(finished.folder) · \(ago)")
        }
        if let usage = claude.usageText { parts.append(usage) }
        return parts.joined(separator: " · ")
    }
}

/// Şarkı bilgisi + butonlar + ilerleme çubuğu + (varsa) kayan sözler.
struct MusicPanel: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var lyrics: LyricsStore
    let track: Track
    /// İki parmakla kaydırma ilerlemesi (-1 önceki ... 1 sonraki) ve yeni biten kaydırma.
    var swipeProgress: CGFloat = 0
    var swipeFlash: SwipeDirection?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ArtworkView(image: player.artwork, size: 58, corner: 12)
                    .onTapGesture { player.activatePlayer() }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: track.title.isEmpty ? "Bilinmeyen şarkı" : track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(verbatim: track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    ControlButton(symbol: "backward.fill", size: 15, emphasis: emphasis(.previous)) {
                        player.previous()
                    }
                    ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                        player.togglePlay()
                    }
                    ControlButton(symbol: "forward.fill", size: 15, emphasis: emphasis(.next)) {
                        player.next()
                    }
                }
                .foregroundStyle(.white)
            }
            .offset(x: swipeProgress * 6) // parmakları hafifçe takip etsin
            ProgressRow(player: player, duration: track.duration)
            if lyrics.hasContent {
                LyricsSection(lyrics: lyrics, player: player)
                    .frame(height: 72)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    /// Kaydırdıkça ilgili buton büyür; kaydırma bitince kısa süre parlar.
    private func emphasis(_ direction: SwipeDirection) -> CGFloat {
        if swipeFlash == direction { return 1 }
        let value = direction == .next ? swipeProgress : -swipeProgress
        return min(max(value, 0), 1)
    }
}

/// Geçen süre — çubuk — kalan süre.
struct ProgressRow: View {
    @ObservedObject var player: NowPlaying
    let duration: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = player.currentPosition(at: context.date)
            HStack(spacing: 10) {
                Text(verbatim: Self.format(position))
                    .frame(width: 34, alignment: .leading)
                ProgressBar(progress: duration > 0 ? position / duration : 0, color: player.accent,
                            dragging: $player.scrubFraction) { fraction in
                    if duration > 0 { player.seek(to: fraction * duration) }
                }
                Text(verbatim: duration > 0 ? "-" + Self.format(duration - position) : "--:--")
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Hiçbir şey çalmıyorken: saat, tarih, sıradaki takvim etkinliği ve Müzik'i açma butonu.
struct IdlePanel: View {
    @ObservedObject var player: NowPlaying
    let agenda: CalendarAgenda

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: Self.clock.string(from: context.date))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(verbatim: Self.day.string(from: context.date))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    AgendaLine(agenda: agenda, now: context.date)
                        .padding(.top, 5)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    if let track = player.track {
                        // Müzik bir süredir duraklatılmış: kaldığın yerden devam et
                        Text(verbatim: "Son çalan")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                        PillButton(title: track.title.isEmpty ? "Devam et" : track.title, symbol: "play.fill") {
                            player.togglePlay()
                        }
                    } else {
                        Text(verbatim: player.permissionDenied ? "Müzik'e erişim izni yok" : "Şu an bir şey çalmıyor")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                        if player.permissionDenied {
                            PillButton(title: "İzin ver", symbol: "lock.open.fill") { player.openAutomationSettings() }
                        } else {
                            PillButton(title: "Müzik'i aç", symbol: "music.note") { player.openMusicApp() }
                        }
                    }
                }
                .frame(maxWidth: 230, alignment: .trailing)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM EEEE"
        return formatter
    }()
}
