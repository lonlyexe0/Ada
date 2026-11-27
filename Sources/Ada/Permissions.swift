import AppKit
import Darwin

// Claude Code'un izin isteğini çentikten cevaplamak.
//
// Akış: Claude Code izin penceresini açmadan önce "PermissionRequest" kancasını çalıştırır
// (`Ada --claude-permission`). Kanca, çalışan Ada'ya yerel bir soketten sorar ve cevabı bekler:
//   - "İzin ver"  → sadece bu seferlik izin (kalıcı kural eklemez, izin modunu değiştirmez)
//   - "Reddet"    → reddeder
//   - Ada kapalıysa, süre dolarsa, Claude penceresi zaten öndeyse ya da "Claude'da aç" dersen
//     kanca hiçbir şey yazmaz → Claude'un kendi izin penceresi her zamanki gibi açılır.
// Cevap sadece senin çentikteki butona basmanla gider; başka bir yoldan "izin ver" demenin yolu yok.
// Komutun tamamı çentiğe sığmıyorsa "İzin ver" butonu hiç çıkmaz (görmediğin şeyi onaylama diye).

/// Kancadan Ada'ya giden istek.
struct PermissionPayload: Sendable {
    let tool: String
    let detail: String
    let folder: String
    let wait: Double
    /// Açıklama isteğin tamamını gösteriyor mu? (Uzun komutlar çentikten onaylanamaz.)
    let complete: Bool
    /// Claude masaüstü uygulamasından mı geldi (değilse terminaldeki Claude Code)?
    let fromDesktop: Bool

    init(tool: String, detail: String, folder: String, wait: Double, complete: Bool, fromDesktop: Bool) {
        self.tool = tool
        self.detail = detail
        self.folder = folder
        self.wait = wait
        self.complete = complete
        self.fromDesktop = fromDesktop
    }

    init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool"] as? String else { return nil }
        self.init(tool: tool,
                  detail: object["detail"] as? String ?? "",
                  folder: object["folder"] as? String ?? "",
                  wait: (object["wait"] as? NSNumber)?.doubleValue ?? PermissionSocket.defaultWait,
                  complete: object["complete"] as? Bool ?? false,
                  fromDesktop: object["desktop"] as? Bool ?? false)
    }

    var jsonLine: String {
        let object: [String: Any] = ["tool": tool, "detail": detail, "folder": folder, "wait": wait,
                                     "complete": complete, "desktop": fromDesktop]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Senin cevabın.
enum PermissionReply: String, Sendable {
    case allow  // izin ver (bu seferlik)
    case deny   // reddet
    case pass   // karar Claude'un kendi penceresine kalsın
}

// MARK: - Soket

/// Ada ile kanca arasındaki yerel soket. Sadece senin kullanıcın erişebilir (klasör 0700, soket 0600).
enum PermissionSocket {
    /// Çentikte cevap için beklenen süre (saniye). Sonra Claude'un kendi penceresi açılır.
    static let defaultWait: Double = 30

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ada", isDirectory: true)
    }

    static var path: String { directory.appendingPathComponent("permission.sock").path }

    private static func address() -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Kapanmış bir sokete yazınca uygulama çökmesin.
    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func receiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func attach(_ fd: Int32, bind shouldBind: Bool) -> Bool {
        guard var address = address() else { return false }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                shouldBind ? Darwin.bind(fd, socketAddress, length) : Darwin.connect(fd, socketAddress, length)
            }
        }
        return result == 0
    }

    static func send(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    /// Bir satır oku (en fazla 64 KB).
    static func receiveLine(_ fd: Int32) -> String? {
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(10) { break }
        }
        guard !data.isEmpty else { return nil }
        let line = data.split(separator: 10, maxSplits: 1, omittingEmptySubsequences: false).first ?? []
        return String(decoding: line, as: UTF8.self)
    }
}

// MARK: - Ada tarafı (sunucu)

/// Kancadan gelen izin isteklerini dinler; cevabı sen butona basınca gönderir.
final class PermissionServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ada.permission")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var nextID = 1
    /// Cevap bekleyen bağlantılar. Kanca kapanırsa (Claude Code vazgeçerse) buradan haberimiz olur.
    private var watchers: [Int: DispatchSourceRead] = [:]

    /// Yeni istek gelince ana thread'de çağrılır. Son parametre cevabı kancaya gönderir.
    var onRequest: (@MainActor (Int, PermissionPayload, @escaping @Sendable (PermissionReply) -> Void) -> Void)?
    /// Kanca cevap beklemeyi bıraktı (Claude Code durdurdu): kart kalksın.
    var onCancel: (@MainActor (Int) -> Void)?

    func start() {
        queue.async { self.startListening() }
    }

    private func startListening() {
        try? FileManager.default.createDirectory(at: PermissionSocket.directory, withIntermediateDirectories: true)
        chmod(PermissionSocket.directory.path, 0o700)
        unlink(PermissionSocket.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        PermissionSocket.noSigPipe(fd)
        guard PermissionSocket.attach(fd, bind: true) else {
            close(fd)
            return
        }
        chmod(PermissionSocket.path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        self.source = source
    }

    private func acceptClient() {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        PermissionSocket.noSigPipe(client)
        PermissionSocket.receiveTimeout(client, seconds: 2)
        guard let line = PermissionSocket.receiveLine(client), let payload = PermissionPayload(jsonLine: line) else {
            close(client)
            return
        }
        let id = nextID
        nextID += 1

        // Kanca bir şey yazmaz; soket okunabilir olduysa kanca kapanmış demektir.
        let watcher = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        watcher.setEventHandler { [weak self] in self?.checkClient(id, fd: client) }
        watcher.setCancelHandler { close(client) }
        watchers[id] = watcher
        watcher.resume()

        let reply: @Sendable (PermissionReply) -> Void = { [weak self] answer in
            guard let self else { return }
            self.queue.async { self.send(answer, id: id, fd: client) }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let handler = self?.onRequest {
                    handler(id, payload, reply)
                } else {
                    reply(.pass)
                }
            }
        }
    }

    private func send(_ answer: PermissionReply, id: Int, fd: Int32) {
        guard let watcher = watchers.removeValue(forKey: id) else { return } // kanca zaten gitmiş
        _ = PermissionSocket.send(fd, "{\"decision\":\"\(answer.rawValue)\"}\n")
        watcher.cancel() // soketi kapatır
    }

    private func checkClient(_ id: Int, fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
        if count > 0 { return } // beklenmeyen veri: yok say
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
        guard let watcher = watchers.removeValue(forKey: id) else { return }
        watcher.cancel()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onCancel?(id) }
        }
    }
}

/// Çentikte gösterilen izin isteği.
struct PermissionPrompt: Equatable, Identifiable {
    let id: Int
    let tool: String
    let detail: String
    let folder: String
    let complete: Bool
    let fromDesktop: Bool
    let arrived: Date
    let deadline: Date

    var toolName: String { Self.displayName(tool) }

    /// "mcp__sunucu__arac" gibi uzun adları kısalt.
    static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3 else { return tool }
        let name = parts[2...].joined(separator: "__")
        return parts[1].count <= 18 ? "\(parts[1]) · \(name)" : name
    }
}

/// Bekleyen izin istekleri. Cevap sadece `answer` ile (yani çentikteki butonlardan) gider.
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var current: PermissionPrompt?
    private var pending: [PermissionPrompt] = []
    private var senders: [Int: @Sendable (PermissionReply) -> Void] = [:]
    /// Gösterilen kart ne zaman öne geldi?
    private var currentSince = Date()
    /// Kart imlecin altında aniden belirince (ya da bir önceki kartı onaylarken çift tıklayınca)
    /// yanlışlıkla izin verilmesin: kart göründükten sonraki ilk anda "İzin ver" sayılmaz.
    static let allowDelay: TimeInterval = 0.8

    var isPending: Bool { current != nil }

    private func show(_ prompt: PermissionPrompt?) {
        current = prompt
        currentSince = Date()
    }

    func enqueue(id: Int, payload: PermissionPayload, reply: @escaping @Sendable (PermissionReply) -> Void) {
        let now = Date()
        let wait = min(max(1, payload.wait), 120)
        let prompt = PermissionPrompt(id: id, tool: payload.tool, detail: payload.detail, folder: payload.folder,
                                      complete: payload.complete, fromDesktop: payload.fromDesktop,
                                      arrived: now, deadline: now.addingTimeInterval(wait))
        senders[id] = reply
        pending.append(prompt)
        if current == nil { show(prompt) }
        AdaLog.write("izin isteği: \(prompt.toolName)")
        // Süre dolunca kendiliğinden düşer → Claude kendi izin penceresini açar.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.finish(id, with: nil, reason: "süre doldu")
        }
    }

    /// Sadece çentikteki butonlardan çağrılır.
    func answer(_ reply: PermissionReply) {
        guard let current else { return }
        if reply == .allow {
            guard current.complete else { return } // tamamı görünmeyen istek çentikten onaylanmaz
            guard Date().timeIntervalSince(currentSince) >= Self.allowDelay else { return } // yanlışlıkla tık
        }
        finish(current.id, with: reply, reason: reply.rawValue)
    }

    /// Kanca vazgeçti (Claude Code durdurdu ya da zaman aşımı): kartı kaldır.
    func cancel(_ id: Int) {
        guard senders.removeValue(forKey: id) != nil else { return }
        remove(id)
        AdaLog.write("izin isteği vazgeçildi")
    }

    private func finish(_ id: Int, with reply: PermissionReply?, reason: String) {
        guard let send = senders.removeValue(forKey: id) else { return }
        send(reply ?? .pass)
        remove(id)
        AdaLog.write("izin cevabı: \(reason)")
    }

    private func remove(_ id: Int) {
        pending.removeAll { $0.id == id }
        if current?.id == id { show(pending.first) }
    }

    func loadPreview(_ on: Bool) {
        let now = Date()
        show(on ? PermissionPrompt(id: 0, tool: "Bash", detail: "npm run build && npm test", folder: "Ada",
                                   complete: true, fromDesktop: true,
                                   arrived: now, deadline: now.addingTimeInterval(24)) : nil)
    }
}

// MARK: - Kanca tarafı (istemci)

/// `Ada --claude-permission` → Claude Code "PermissionRequest" kancası.
enum PermissionHook {
    /// Bunlar izin değil, senden cevap bekleyen sorular: hep Claude'un kendi penceresinde kalsın.
    private static let interactiveTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "EnterPlanMode"]
    /// Çentikte gösterilen en uzun açıklama. Daha uzunsa "İzin ver" çıkmaz.
    private static let limit = 180

    static func run() {
        guard isatty(STDIN_FILENO) == 0 else { return }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        let tool = json["tool_name"] as? String ?? "?"
        guard !interactiveTools.contains(tool) else { return }
        let cwd = json["cwd"] as? String ?? ""
        let environment = ProcessInfo.processInfo.environment
        let wait = Double(environment["ADA_PERMISSION_WAIT"] ?? "") ?? PermissionSocket.defaultWait
        let summary = summarize(json["tool_input"] as? [String: Any] ?? [:], cwd: cwd)
        let payload = PermissionPayload(
            tool: tool, detail: summary.text,
            folder: cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent,
            wait: min(max(1, wait), 120), complete: summary.complete,
            fromDesktop: (environment["CLAUDE_CODE_ENTRYPOINT"] ?? "").contains("desktop"))

        switch ask(payload) {
        case .allow?:
            print(output(["behavior": "allow"]))
        case .deny?:
            print(output(["behavior": "deny", "message": "The user denied this request from the Ada notch app."]))
        default:
            break // karar yok → Claude'un kendi izin penceresi açılır
        }
        fflush(stdout)
    }

    /// Kancanın Claude Code'a yazdığı cevap (resmi biçim: hookSpecificOutput.decision.behavior).
    private static func output(_ decision: [String: String]) -> String {
        let object: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Çentikte gösterilecek açıklama: komut, dosya yolu, adres... Tamamı sığdı mı?
    private static func summarize(_ input: [String: Any], cwd: String) -> (text: String, complete: Bool) {
        var text: String
        if let command = input["command"] as? String {
            text = command.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ⏎ ")
        } else if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
            text = shortPath(path, cwd: cwd)
        } else if let url = input["url"] as? String {
            text = url
        } else if let pattern = input["pattern"] as? String {
            text = pattern
        } else if let query = input["query"] as? String {
            text = query
        } else if input.isEmpty {
            text = ""
        } else {
            // Bilinmeyen araç (ör. MCP): girdinin kendisi
            let data = (try? JSONSerialization.data(withJSONObject: input,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            text = String(decoding: data, as: UTF8.self)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return (text, true) }
        return (String(text.prefix(limit)) + "…", false)
    }

    private static func shortPath(_ path: String, cwd: String) -> String {
        if !cwd.isEmpty, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    /// Ada'ya sor, cevabı bekle. Ada kapalıysa ya da cevap gelmezse nil.
    private static func ask(_ payload: PermissionPayload) -> PermissionReply? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        PermissionSocket.noSigPipe(fd)
        guard PermissionSocket.attach(fd, bind: false) else { return nil } // Ada çalışmıyor
        guard PermissionSocket.send(fd, payload.jsonLine + "\n") else { return nil }
        // Süre dolunca Ada kendisi "pass" der; 2 sn fazladan bekleyelim ki karar hep Ada'dan gelsin.
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32((payload.wait + 2) * 1000)) > 0 else { return nil }
        PermissionSocket.receiveTimeout(fd, seconds: 2)
        guard let line = PermissionSocket.receiveLine(fd),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decision = object["decision"] as? String else { return nil }
        return PermissionReply(rawValue: decision)
    }
}
