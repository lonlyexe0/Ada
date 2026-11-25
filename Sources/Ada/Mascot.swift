import AppKit
import QuartzCore
import SwiftUI

enum MascotColors {
    static let orange = NSColor(srgbRed: 0.87, green: 0.46, blue: 0.34, alpha: 1)
    static let orangeSwiftUI = Color(nsColor: orange)
}

/// Maskotun boyu. Bir pikselin boyu Retina ekranda tam piksele denk gelmeli:
/// yoksa kareler yarım piksele düşer, bir göz bulanık çizilip "şaşı" görünür.
struct MascotStyle: Equatable {
    let cell: CGFloat       // bir pikselin boyu (point)
    let outline: CGFloat    // beyaz çıkartma kenarı
    let size: CGSize        // görünümün boyu
    let topMargin: CGFloat  // üstten boşluk

    /// Çentiğin altından sarkan büyük hali (Retina'da her piksel 6×6).
    static let big = MascotStyle(cell: 3, outline: 1, size: CGSize(width: 66, height: 38), topMargin: 3)
    /// "Çalışıyor" göstergesindeki küçük hali (Retina'da her piksel 3×3).
    static let mini = MascotStyle(cell: 1.5, outline: 0.5, size: CGSize(width: 24, height: 19.5), topMargin: 1.5)
}

/// Claude'un piksel maskotu.
struct MascotView: View {
    var style: MascotStyle = .big
    /// true: onayını bekliyor (yanında zıplayan "?", bacaklar durur)
    var asking = false
    /// true: kıpırdamadan durur, sadece göz kırpar (✓ rozetinde)
    var still = false

    var body: some View {
        Group {
            if Snapshot.isRendering {
                // Resim çıkarırken: aynı katmanları sabit bir resme çiz
                Image(nsImage: MascotLayerView.image(style: style, asking: asking, still: still))
            } else {
                MascotRepresentable(style: style, asking: asking, still: still)
            }
        }
        .frame(width: style.size.width, height: style.size.height)
    }
}

private struct MascotRepresentable: NSViewRepresentable {
    let style: MascotStyle
    let asking: Bool
    let still: Bool

    func makeNSView(context: Context) -> MascotLayerView { MascotLayerView(style: style, still: still) }

    func updateNSView(_ view: MascotLayerView, context: Context) { view.setAsking(asking) }
}

/// Piksel maskot: 14 × 11'lik bir ızgaradan Core Animation katmanlarıyla çiziliyor.
/// Bacak oynatma, göz kırpma ve "?" zıplaması macOS'un ekran sunucusunda döner; Ada her karede iş yapmaz.
///
///     satır 0-2 :  . # # # # # # # # # # # # .      # # .     ("?": 15-17. sütunlar,
///     satır 3   :  . # # o # # # # # # o # # .      . . #      sadece onay beklerken)
///     satır 4   :  . # # # # # # # # # # # # .      . # .
///     satır 5-7 :  # # # # # # # # # # # # # #      . . .
///     satır 8   :  . # # # # # # # # # # # # .      . # .
///     satır 9-10:  . . # . # . . . . # . # . .      (dört bacak)
final class MascotLayerView: NSView {
    private let style: MascotStyle
    private let still: Bool
    private let host = CALayer()
    private let figure = CALayer()
    private var legsA = CALayer()       // 1. ve 3. bacak
    private var legsB = CALayer()       // 2. ve 4. bacak
    private var eyes = CAShapeLayer()
    private var question = CALayer()    // onay beklerken yanında zıplayan "?"
    private var asking = false
    private let pixelScale = NSScreen.main?.backingScaleFactor ?? 2

    init(style: MascotStyle, still: Bool = false) {
        self.style = style
        self.still = still
        super.init(frame: NSRect(origin: .zero, size: style.size))
        host.masksToBounds = false
        host.frame = CGRect(origin: .zero, size: style.size)
        layer = host       // katmanı biz yönetiyoruz
        wantsLayer = true
        build()
        applyAnimations()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // tıklamaları engellemesin

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = CGRect(origin: .zero, size: newSize)
        CATransaction.commit()
    }

    func setAsking(_ asking: Bool) {
        guard asking != self.asking else { return }
        self.asking = asking
        applyAnimations()
    }

    /// Snapshot için: maskotu sabit bir resme çizer.
    static func image(style: MascotStyle, asking: Bool, still: Bool = false) -> NSImage {
        let size = style.size
        let view = MascotLayerView(style: style, still: still)
        view.setAsking(asking)
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }
        context.scaleBy(x: scale, y: scale)
        view.host.render(in: context)
        guard let cgImage = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: Çizim

    /// Izgaradaki hücre(ler)in katman dikdörtgeni. Satır 0 en üstte (Core Animation'da y yukarı doğru).
    private func cells(_ column: CGFloat, _ row: CGFloat, _ width: CGFloat = 1, _ height: CGFloat = 1) -> CGRect {
        let left = (style.size.width - 14 * style.cell) / 2
        let top = style.size.height - style.topMargin
        return CGRect(x: left + column * style.cell, y: top - (row + height) * style.cell,
                      width: width * style.cell, height: height * style.cell)
    }

    private func build() {
        let orange = MascotColors.orange.cgColor
        let white = NSColor.white.cgColor
        let o = style.outline

        figure.frame = CGRect(origin: .zero, size: style.size)
        host.addSublayer(figure)

        // Bacaklar gövdenin arkasında: yukarı kalkınca gövdenin altına girer.
        legsA = legs(columns: [2, 9], orange: orange, white: white)
        legsB = legs(columns: [4, 11], orange: orange, white: white)
        figure.addSublayer(legsA)
        figure.addSublayer(legsB)

        // Gövde + kollar: önce beyaz kenar, üstüne turuncu
        let body = cells(1, 0, 12, 5)
        let arms = cells(0, 5, 14, 3)
        let bottom = cells(1, 8, 12, 1)
        let edge = CGMutablePath()
        edge.addRect(body.insetBy(dx: -o, dy: -o))
        edge.addRect(arms.insetBy(dx: -o, dy: -o))
        // alt sıra: bacaklarla arasına beyaz çizgi girmesin diye alttan kenar yok
        edge.addRect(CGRect(x: bottom.minX - o, y: bottom.minY, width: bottom.width + 2 * o, height: bottom.height + o))
        figure.addSublayer(filled(edge, white))
        let fill = CGMutablePath()
        fill.addRect(body)
        fill.addRect(arms)
        fill.addRect(bottom)
        figure.addSublayer(filled(fill, orange))

        // Gözler: iki siyah piksel, kenarlardan iki piksel içeride (ileri bakar).
        // Göz kırpma için kendi katmanında; katmanın ortası göz satırı.
        let eyeRow = cells(0, 3)
        let eyeLayer = CAShapeLayer()
        eyeLayer.frame = CGRect(x: 0, y: eyeRow.minY, width: style.size.width, height: style.cell)
        let eyePath = CGMutablePath()
        for column: CGFloat in [3, 10] {
            let eye = cells(column, 3)
            eyePath.addRect(CGRect(x: eye.minX, y: 0, width: eye.width, height: eye.height))
        }
        eyeLayer.path = eyePath
        eyeLayer.fillColor = NSColor.black.cgColor
        eyeLayer.contentsScale = pixelScale
        figure.addSublayer(eyeLayer)
        eyes = eyeLayer

        // "?" (3×5 piksel), sadece onay beklerken görünür
        let mark = CALayer()
        mark.frame = CGRect(origin: .zero, size: style.size)
        let markEdge = CGMutablePath()
        let markFill = CGMutablePath()
        let pixels: [(CGFloat, CGFloat)] = [(15, 0), (16, 0), (17, 1), (16, 2), (16, 4)]
        for (column, row) in pixels {
            let pixel = cells(column, row)
            markEdge.addRect(pixel.insetBy(dx: -o, dy: -o))
            markFill.addRect(pixel)
        }
        mark.addSublayer(filled(markEdge, white))
        mark.addSublayer(filled(markFill, orange))
        mark.isHidden = true
        figure.addSublayer(mark)
        question = mark
    }

    private func legs(columns: [CGFloat], orange: CGColor, white: CGColor) -> CALayer {
        let group = CALayer()
        group.frame = CGRect(origin: .zero, size: style.size)
        let o = style.outline
        let edge = CGMutablePath()
        let fill = CGMutablePath()
        for column in columns {
            let leg = cells(column, 9, 1, 2)
            // kenar sadece yanlarda ve altta (üstü gövdeye bağlı)
            edge.addRect(CGRect(x: leg.minX - o, y: leg.minY - o, width: leg.width + 2 * o, height: leg.height + o))
            fill.addRect(leg)
        }
        group.addSublayer(filled(edge, white))
        group.addSublayer(filled(fill, orange))
        return group
    }

    private func filled(_ path: CGPath, _ color: CGColor) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = CGRect(origin: .zero, size: style.size)
        shape.path = path
        shape.fillColor = color
        shape.contentsScale = pixelScale
        return shape
    }

    // MARK: Animasyon (piksel tarzı: ara kare yok, tam bir piksel adımla)

    private func applyAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        legsA.removeAllAnimations()
        legsB.removeAllAnimations()
        question.removeAllAnimations()
        question.isHidden = !asking
        if asking {
            // Bekliyor: bacaklar durur, "?" zıplar
            question.add(Self.step([0, -style.cell], period: 0.6), forKey: "bounce")
        } else if !still {
            // Çalışıyor / işini bitirdi: bacaklar sırayla kalkıp iner
            legsA.add(Self.step([0, style.cell], period: 0.36), forKey: "legs")
            legsB.add(Self.step([style.cell, 0], period: 0.36), forKey: "legs")
        }
        if eyes.animation(forKey: "blink") == nil {
            eyes.add(Self.blink(period: 2.8), forKey: "blink")
        }
        CATransaction.commit()
    }

    /// İki konum arasında adım adım gidip gelme.
    private static func step(_ values: [CGFloat], period: Double) -> CAAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = values
        animation.keyTimes = [0, 0.5, 1]
        animation.calculationMode = .discrete
        animation.duration = period
        animation.repeatCount = .infinity
        return animation
    }

    /// Göz kırpma: periyodun sonunda kısa süre kapanır.
    private static func blink(period: Double) -> CAAnimation {
        let closed = 0.16 / period
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        animation.values = [1, 0.25]
        animation.keyTimes = [0, NSNumber(value: 1 - closed), 1]
        animation.calculationMode = .discrete
        animation.duration = period
        animation.repeatCount = .infinity
        return animation
    }
}
