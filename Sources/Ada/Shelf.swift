import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dosya rafı: çentiğe sürüklenen dosyaları tutar (dosyanın kendisini değil, yerini).
/// Oradan başka yere sürükleyebilir ya da AirDrop'la gönderebilirsin.
@MainActor
final class FileShelf: ObservableObject {
    @Published private(set) var files: [URL] = []
    /// Bir dosya rafın üstünde sürükleniyor mu (bırakma alanı parlasın).
    @Published var isTargeted = false

    static let limit = 12
    private static let key = "shelfFiles"
    private let isPreview: Bool

    init(preview: Bool = false) {
        isPreview = preview
        guard !preview else { return }
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        files = saved.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            files.removeAll { $0 == url }
            files.insert(url, at: 0)
        }
        if files.count > Self.limit { files.removeLast(files.count - Self.limit) }
        save()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        save()
    }

    func clear() {
        files.removeAll()
        save()
    }

    private func save() {
        guard !isPreview else { return }
        UserDefaults.standard.set(files.map(\.path), forKey: Self.key)
    }

    /// Taşınmış / silinmiş dosyaları raftan düşür.
    func pruneMissing() {
        guard !isPreview else { return }
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing != files {
            files = existing
            save()
        }
    }

    func airDrop(_ urls: [URL]? = nil) {
        let items = urls ?? files
        guard !items.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: items) else { return }
        NSApp.activate()
        service.perform(withItems: items)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Sürükle-bırak ile gelen dosyalar.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: NSURL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                guard let url = object as? URL else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.add([url]) }
                }
            }
        }
        return accepted
    }

    /// Dosyanın simgesi (dosya yoksa türünün simgesi).
    static func icon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }

    // MARK: Önizleme (snapshot)

    static let previewFiles: [URL] = ["Fizik ödevi.pdf", "tatil.jpg", "sunum.key", "notlar.txt"]
        .map { URL(fileURLWithPath: "/tmp/ada-onizleme/\($0)") }

    func loadPreview(_ urls: [URL]) {
        files = urls
    }
}

/// "Raf" sekmesi.
struct ShelfView: View {
    @ObservedObject var shelf: FileShelf

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            if shelf.files.isEmpty {
                dropZone
            } else {
                items
                HStack(spacing: 8) {
                    PillButton(title: "AirDrop ile gönder", symbol: "dot.radiowaves.left.and.right") { shelf.airDrop() }
                    Spacer()
                    PillButton(title: "Rafı boşalt", symbol: "trash") { shelf.clear() }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(shelf.isTargeted ? 0.7 : 0), lineWidth: 2)
                .padding(4)
        )
        // (Resim çıkarırken bırakma alanı çizilemiyor; sadece gerçek uygulamada)
        if Snapshot.isRendering {
            content
        } else {
            content
                .onDrop(of: [UTType.fileURL], isTargeted: $shelf.isTargeted) { providers in
                    shelf.handleDrop(providers)
                }
                .onAppear { shelf.pruneMissing() }
        }
    }

    @ViewBuilder
    private var items: some View {
        let row = HStack(spacing: 8) {
            ForEach(shelf.files, id: \.self) { url in
                ShelfItem(url: url, shelf: shelf)
            }
        }
        // (Resim çıkarırken kaydırma alanı çizilemiyor, düz satır kullan)
        if Snapshot.isRendering {
            row.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 20, weight: .semibold))
            Text(verbatim: shelf.isTargeted ? "Bırak!" : "Dosyaları çentiğe sürükleyip buraya bırak")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(shelf.isTargeted ? 0.9 : 0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.white.opacity(0.25))
        )
    }
}

/// Raftaki tek dosya: simge + ad. Tıklayınca açılır, sürükleyince dışarı alınır, sağ tıkla menü.
struct ShelfItem: View {
    let url: URL
    @ObservedObject var shelf: FileShelf

    var body: some View {
        let content = VStack(spacing: 3) {
            Image(nsImage: FileShelf.icon(for: url))
                .resizable()
                .frame(width: 34, height: 34)
            Text(verbatim: url.lastPathComponent)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 60, height: 54)
        .contentShape(Rectangle())
        if Snapshot.isRendering {
            content
        } else {
            content
                .onTapGesture { shelf.open(url) }
                .onDrag { NSItemProvider(object: url as NSURL) }
                .contextMenu {
                    Button("Finder'da göster") { shelf.reveal(url) }
                    Button("AirDrop ile gönder") { shelf.airDrop([url]) }
                    Button("Raftan kaldır") { shelf.remove(url) }
                }
        }
    }
}
