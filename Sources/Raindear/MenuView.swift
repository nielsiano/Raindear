import RainSynth
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var player: RainPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            volume
            Divider()
            presetPicker
            VStack(spacing: 8) {
                ParameterSlider(title: "Rain", symbol: "cloud.rain", value: $player.settings.rain)
                ParameterSlider(title: "Drops", symbol: "drop", value: $player.settings.drops)
                ParameterSlider(title: "Rumble", symbol: "waveform", value: $player.settings.rumble)
                ParameterSlider(title: "Tone", symbol: "dial.medium", value: $player.settings.tone)
                ParameterSlider(title: "Wind", symbol: "wind", value: $player.settings.wind)
                ParameterSlider(title: "Thunder", symbol: "cloud.bolt", value: $player.settings.thunder)
            }
            if let message = player.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Raindear")
                    .font(.headline)
                Text(player.isPlaying ? "Playing" : "Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")
        }
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
            Slider(value: $player.settings.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private var presetPicker: some View {
        Picker("Preset", selection: presetSelection) {
            ForEach(RainPreset.all) { preset in
                Text(preset.name).tag(preset.id)
            }
            if player.currentPreset == nil {
                Divider()
                Text("Custom").tag(Self.customTag)
            }
        }
        .pickerStyle(.menu)
    }

    private static let customTag = "custom"

    private var presetSelection: Binding<String> {
        Binding(
            get: { player.currentPreset?.id ?? Self.customTag },
            set: { id in
                if let preset = RainPreset.all.first(where: { $0.id == id }) {
                    player.apply(preset)
                }
            }
        )
    }

    private var footer: some View {
        HStack {
            Toggle(
                "Launch at login",
                isOn: Binding(get: { player.launchAtLogin }, set: { player.setLaunchAtLogin($0) })
            )
            .toggleStyle(.checkbox)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

private struct ParameterSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .frame(width: 58, alignment: .leading)
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}
