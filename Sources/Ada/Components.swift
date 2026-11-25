import SwiftUI

/// Çentik şekli: üst köşeler içe kıvrılıp menü çubuğuna karışır, alt köşeler yuvarlak.
/// İki yarıçap da animasyonla değişebilir.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = min(bottomRadius, (rect.width - top * 2) / 2, rect.height - top)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // sol üst: içbükey kıvrım
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // sol alt
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // sağ alt
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // sağ üst: içbükey kıvrım
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Albüm kapağı (yoksa nota ikonu).
struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.12)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Zıplayan 4 çubuk. Müzik durunca alçalır.
/// Core Animation ile çalışır: müzik çalarken bile Ada her karede iş yapmaz.
struct EqualizerView: View {
    var color: Color
    var isPlaying: Bool

    var body: some View {
        if Snapshot.isRendering {
            StaticEqualizer(color: color, isPlaying: isPlaying)
        } else {
            EqualizerRepresentable(color: NSColor(color), isPlaying: isPlaying)
        }
    }
}

private struct EqualizerRepresentable: NSViewRepresentable {
    let color: NSColor
    let isPlaying: Bool

    func makeNSView(context: Context) -> EqualizerLayerView { EqualizerLayerView(frame: .zero) }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.configure(color: color, playing: isPlaying)
    }
}

/// Resim (snapshot) çıkarırken kullanılan sabit çubuklar.
private struct StaticEqualizer: View {
    let color: Color
    let isPlaying: Bool

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: geo.size.width * 0.14) {
                ForEach(Array([0.55, 0.95, 0.4, 0.75].enumerated()), id: \.offset) { item in
                    Capsule()
                        .fill(color)
                        .frame(height: max(2.5, geo.size.height * (isPlaying ? item.element : 0.2)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

final class EqualizerLayerView: NSView {
    private let host = CALayer()
    private var bars: [CALayer] = []
    private var color: NSColor = .white
    private var running = false

    /// Her çubuğun kendi yükseklik dizisi ve hızı (birbirine benzemesinler).
    private let patterns: [[CGFloat]] = [
        [0.30, 0.85, 0.45, 1.00, 0.35, 0.70, 0.30],
        [0.60, 0.25, 0.95, 0.40, 0.80, 0.30, 0.60],
        [0.40, 1.00, 0.30, 0.65, 0.95, 0.25, 0.40],
        [0.75, 0.35, 0.60, 0.20, 0.90, 0.50, 0.75],
    ]
    private let durations: [Double] = [1.9, 1.45, 2.3, 1.7]

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.masksToBounds = false
        layer = host
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            bar.transform = CATransform3DMakeScale(1, 0.2, 1)
            host.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = CGRect(origin: .zero, size: newSize)
        let gap = newSize.width * 0.14
        let barWidth = max(1, (newSize.width - gap * 3) / 4)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: newSize.height)
            bar.position = CGPoint(x: CGFloat(index) * (barWidth + gap) + barWidth / 2, y: newSize.height / 2)
            bar.cornerRadius = barWidth / 2
        }
        CATransaction.commit()
    }

    func configure(color: NSColor, playing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if color != self.color {
            self.color = color
            bars.forEach { $0.backgroundColor = color.cgColor }
        }
        if playing != running {
            running = playing
            for (index, bar) in bars.enumerated() {
                bar.removeAnimation(forKey: "eq")
                if playing {
                    let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                    animation.values = patterns[index]
                    animation.duration = durations[index]
                    animation.calculationMode = .cubic
                    animation.repeatCount = .infinity
                    bar.transform = CATransform3DIdentity
                    bar.add(animation, forKey: "eq")
                } else {
                    bar.transform = CATransform3DMakeScale(1, 0.2, 1)
                }
            }
        }
        CATransaction.commit()
    }
}

/// Küçük pil çizimi.
struct BatteryGlyph: View {
    var level: Int
    var charging: Bool

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(fill)
                    .frame(width: max(2, 20 * CGFloat(min(max(level, 0), 100)) / 100), height: 8)
                    .padding(.leading, 2)
            }
            .frame(width: 24, height: 12)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.4))
                .frame(width: 1.5, height: 4)
        }
    }

    private var fill: Color {
        if charging { return .green }
        return level <= 20 ? .red : .white
    }
}

/// ⏮ ⏯ ⏭ butonları.
struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    /// 0...1: iki parmakla kaydırırken büyüyüp parlaması için.
    var emphasis: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 10, height: size + 10)
                .background(Circle().fill(Color.white.opacity(0.2 * emphasis)).padding(-6))
                .scaleEffect(1 + 0.22 * emphasis)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Yuvarlak kenarlı küçük buton ("Müzik'i aç" gibi).
struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Basınca hafif küçülen buton stili.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Sürüklenebilir ilerleme çubuğu (tıkla / sürükle → şarkıda o yere atla).
struct ProgressBar: View {
    var progress: Double
    var color: Color
    /// Sürüklenirken parmağın olduğu yer (0...1), değilse nil.
    /// Not: @State kullanmıyoruz; macOS 27'de @State bir makro ve makro eklentisi
    /// sadece Xcode ile geliyor (Command Line Tools ile derlenmiyor).
    let dragging: Binding<Double?>
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let value = CGFloat(min(max(dragging.wrappedValue ?? progress, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(color).frame(width: geo.size.width * value)
            }
            .frame(height: dragging.wrappedValue == nil ? 5 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging.wrappedValue = Self.fraction(drag.location.x, of: geo.size.width)
                    }
                    .onEnded { drag in
                        onSeek(Self.fraction(drag.location.x, of: geo.size.width))
                        dragging.wrappedValue = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging.wrappedValue == nil)
        }
        .frame(height: 14)
    }

    private static func fraction(_ x: CGFloat, of width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }
}
