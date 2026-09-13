import AVFoundation
import RainSynth
import ServiceManagement
import SwiftUI

@MainActor
final class RainPlayer: ObservableObject {
    @Published var settings: RainSettings {
        didSet {
            guard settings != oldValue else { return }
            synth.setSettings(settings)
            save()
        }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var errorMessage: String?

    private static let settingsKey = "settings"

    private let synth: RainSynth
    private let engine = AVAudioEngine()
    private var stopTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?

    init() {
        let settings = Self.loadSettings()
        self.settings = settings
        synth = RainSynth(settings: settings)

        let format = AVAudioFormat(standardFormatWithSampleRate: RainSynth.defaultSampleRate, channels: 2)!
        let source = Self.makeSourceNode(synth: synth, format: format)
        engine.attach(source)
        // The mixer converts to whatever rate the output device runs at.
        engine.connect(source, to: engine.mainMixerNode, format: format)

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputDeviceChanged() }
        }
    }

    var currentPreset: RainPreset? {
        RainPreset.matching(settings)
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        stopTask?.cancel()
        errorMessage = nil
        synth.setPlaying(true)
        do {
            try startEngine()
            isPlaying = true
        } catch {
            synth.setPlaying(false)
            errorMessage = "Could not start audio: \(error.localizedDescription)"
        }
    }

    func pause() {
        synth.setPlaying(false)
        isPlaying = false
        // Let the fade-out finish, then stop the engine so it uses no CPU.
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            self.engine.stop()
        }
    }

    func apply(_ preset: RainPreset) {
        settings = preset.apply(to: settings)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Launch at login: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            errorMessage = "Allow Raindear in System Settings → General → Login Items."
        }
    }

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        if hardware.channelCount > 0 && hardware.sampleRate > 0 {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
        }
        engine.prepare()
        try engine.start()
    }

    /// Headphones plugged in, AirPods connected, and so on. The engine stops
    /// itself when this happens.
    private func outputDeviceChanged() {
        guard isPlaying else { return }
        engine.stop()
        do {
            try startEngine()
        } catch {
            isPlaying = false
            errorMessage = "Audio output changed and could not restart: \(error.localizedDescription)"
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private static func loadSettings() -> RainSettings {
        guard
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let settings = try? JSONDecoder().decode(RainSettings.self, from: data)
        else { return .default }
        return settings
    }

    /// Built outside the main actor so the render closure is not treated as
    /// main-actor code. It runs on the audio thread.
    private nonisolated static func makeSourceNode(synth: RainSynth, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard
                buffers.count >= 2,
                let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            synth.render(left: left, right: right, frameCount: Int(frameCount))
            return noErr
        }
    }
}
