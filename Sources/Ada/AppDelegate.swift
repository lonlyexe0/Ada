import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var island: IslandController?
    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?
    private var mascotItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = IslandController()
        statusItem = makeStatusItem()
        enableLaunchAtLoginOnce()
    }

    // MARK: Menü çubuğu ikonu

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Ada")

        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem(title: "Ada · Dinamik Ada", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(title: "Mac açılınca başlat",
                                       action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        launchAtLoginItem = launchAtLogin

        let mascotToggle = NSMenuItem(title: "Claude maskotunu göster", action: #selector(toggleMascot),
                                      keyEquivalent: "")
        mascotToggle.target = self
        menu.addItem(mascotToggle)
        mascotItem = mascotToggle

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Ada'dan çık",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        return item
    }

    /// Menü açılırken tik işaretini güncelle.
    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        mascotItem?.state = (island?.state.mascotEnabled ?? false) ? .on : .off
    }

    @objc private func toggleMascot() {
        island?.state.mascotEnabled.toggle()
    }

    // MARK: Mac açılınca başlat

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Ada: Mac açılınca başlat ayarı değiştirilemedi: %@", error.localizedDescription)
        }
        // macOS bazen kullanıcı onayı ister → Ayarlar'daki Giriş Öğeleri'ni aç.
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Programlar klasöründen ilk açılışta kendini "Mac açılınca başlat"a ekler.
    /// Sonra menüden kapatılabilir; bir daha kendiliğinden açmaz.
    private func enableLaunchAtLoginOnce() {
        let key = "launchAtLoginConfigured"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.contains("/Applications/") else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Ada: Mac açılınca başlat ayarlanamadı: %@", error.localizedDescription)
        }
    }
}
