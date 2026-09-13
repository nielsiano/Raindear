import AVFoundation
import Foundation
import RainSynth

// Renders rain to a WAV file and prints its levels, so the sound can be
// tuned without running the menu bar app.
//
//   swift run -c release rain-render --preset storm --seconds 30 --out storm.wav
//   swift run -c release rain-render --rain 0 --drops 0 --rumble 1   (one layer alone)

let usage = """
    usage: rain-render [--preset id] [--seconds n] [--out file.wav] [--seed n]
                       [--volume v] [--rain v] [--drops v] [--rumble v] [--tone v] [--wind v] [--thunder v]
    presets: \(RainPreset.all.map(\.id).joined(separator: ", "))
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n\(usage)\n".utf8))
    exit(1)
}

var settings = RainSettings.default
settings.volume = 1
var seconds = 20.0
var outputPath = "rain.wav"
var seed: UInt64 = 1

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let flag = arguments.next() {
    guard let value = arguments.next() else { fail("missing value for \(flag)") }
    func number() -> Double {
        guard let number = Double(value) else { fail("\(flag) expects a number, got \(value)") }
        return number
    }
    switch flag {
    case "--preset":
        guard let preset = RainPreset.all.first(where: { $0.id == value }) else { fail("unknown preset \(value)") }
        settings = preset.apply(to: settings)
    case "--seconds": seconds = number()
    case "--out": outputPath = value
    case "--seed": seed = UInt64(number())
    case "--volume": settings.volume = number()
    case "--rain": settings.rain = number()
    case "--drops": settings.drops = number()
    case "--rumble": settings.rumble = number()
    case "--tone": settings.tone = number()
    case "--wind": settings.wind = number()
    case "--thunder": settings.thunder = number()
    default: fail("unknown option \(flag)")
    }
}

let sampleRate = RainSynth.defaultSampleRate
let synth = RainSynth(settings: settings, playing: true, sampleRate: sampleRate, seed: seed)
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
let fileSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

let file: AVAudioFile
do {
    file = try AVAudioFile(
        forWriting: URL(fileURLWithPath: outputPath),
        settings: fileSettings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
} catch {
    fail("could not create \(outputPath): \(error.localizedDescription)")
}

let chunk: AVAudioFrameCount = 4096
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
let totalFrames = Int(seconds * sampleRate)
let skipFrames = Int(sampleRate) // leave the fade-in out of the stats
var rendered = 0
var peak: Float = 0
var sumSquares: Double = 0
var measured = 0

while rendered < totalFrames {
    let frames = min(Int(chunk), totalFrames - rendered)
    buffer.frameLength = AVAudioFrameCount(frames)
    let left = buffer.floatChannelData![0]
    let right = buffer.floatChannelData![1]
    synth.render(left: left, right: right, frameCount: frames)
    for i in 0..<frames where rendered + i >= skipFrames {
        peak = max(peak, abs(left[i]), abs(right[i]))
        sumSquares += Double(left[i] * left[i] + right[i] * right[i]) / 2
        measured += 1
    }
    do {
        try file.write(from: buffer)
    } catch {
        fail("write failed: \(error.localizedDescription)")
    }
    rendered += frames
}

func decibels(_ value: Double) -> String {
    value > 0 ? String(format: "%.1f dBFS", 20 * log10(value)) : "-inf dBFS"
}

let rms = measured > 0 ? (sumSquares / Double(measured)).squareRoot() : 0
print("wrote \(outputPath) (\(seconds)s)")
print("peak \(decibels(Double(peak)))  rms \(decibels(rms))")
