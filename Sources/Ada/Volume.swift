import AudioToolbox
import CoreAudio
import SwiftUI

/// Sistem sesini SADECE okur, asla değiştirmez.
/// Ses tuşlarına basınca (ya da ses başka yerden değişince) çentikte ses göstergesi çıkar.
@MainActor
final class VolumeMonitor: ObservableObject {
    @Published private(set) var level: Float = 0   // 0...1
    @Published private(set) var muted = false
    /// Menüden açılıp kapatılır ("Ses göstergesi").
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "volumeHUD") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "volumeHUD") }
    }
    /// Ses değişince çağrılır.
    var onChange: (() -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(preview: Bool = false) {
        if preview {
            level = 0.6
            return
        }
        watchDefaultDevice()
        attach(to: Self.defaultOutputDevice())
        AdaLog.write(device == AudioObjectID(kAudioObjectUnknown)
                     ? "ses aygıtı bulunamadı" : "ses göstergesi hazır (sadece okuma)")
    }

    // MARK: Okuma (yazma yok)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private func readVolume() -> Float? {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func readMute() -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    // MARK: Dinleme

    /// Varsayılan çıkış (hoparlör / kulaklık) değişirse yenisini dinle (gösterge çıkarmadan).
    private func watchDefaultDevice() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.attach(to: Self.defaultOutputDevice()) }
        }
    }

    private func attach(to newDevice: AudioObjectID) {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        listeners.removeAll()
        device = newDevice
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        level = readVolume() ?? level
        muted = readMute() ?? muted

        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector, kAudioDevicePropertyScopeOutput)
            guard AudioObjectHasProperty(device, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed() }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func changed() {
        let newLevel = readVolume() ?? level
        let newMuted = readMute() ?? muted
        guard abs(newLevel - level) > 0.001 || newMuted != muted else { return }
        level = newLevel
        muted = newMuted
        if enabled { onChange?() }
    }
}

/// Ses göstergesi (iPhone'daki gibi): solda hoparlör, sağda doluluk çubuğu.
struct VolumeRow: View {
    @ObservedObject var volume: VolumeMonitor
    let notch: NotchMetrics
    let width: CGFloat

    var body: some View {
        let fraction = volume.muted ? 0 : CGFloat(min(max(volume.level, 0), 1))
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, alignment: .leading)
                .padding(.leading, 18)
            Spacer(minLength: notch.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white).frame(width: 46 * fraction)
            }
            .frame(width: 46, height: 5)
            .animation(.easeOut(duration: 0.15), value: fraction)
            .padding(.trailing, 20)
        }
        .frame(width: width, height: notch.height)
    }

    private var symbol: String {
        if volume.muted || volume.level < 0.01 { return "speaker.slash.fill" }
        if volume.level < 0.34 { return "speaker.wave.1.fill" }
        if volume.level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
