import Foundation
import IOKit.ps

/// Pil yüzdesini ve şarj kablosunu takip eder.
@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level = 100
    @Published private(set) var onAC = false
    @Published private(set) var hasBattery = false

    /// Şarj kablosu takılınca çağrılır.
    var onPluggedIn: (() -> Void)?

    private var source: CFRunLoopSource?

    init(preview: Bool = false) {
        if preview {
            level = 72
            onAC = true
            hasBattery = true
            return
        }
        refresh(notify: false)

        // Güç durumu değişince macOS bizi haber eder (kablo takıldı/çıkarıldı, yüzde değişti).
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh(notify: true) }
        }
        if let runLoopSource = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            source = runLoopSource
        }
    }

    func refresh(notify: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [AnyObject] else { return }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery" else { continue }

            let current = description["Current Capacity"] as? Int ?? 0
            let maximum = description["Max Capacity"] as? Int ?? 100
            let newLevel = maximum > 0 ? Int((Double(current) * 100 / Double(maximum)).rounded()) : current
            let newAC = (description["Power Source State"] as? String) == "AC Power"
            let justPluggedIn = notify && newAC && !onAC

            if !hasBattery { hasBattery = true }
            if level != newLevel { level = newLevel }
            if onAC != newAC { onAC = newAC }
            if justPluggedIn { onPluggedIn?() }
            return
        }
    }
}
