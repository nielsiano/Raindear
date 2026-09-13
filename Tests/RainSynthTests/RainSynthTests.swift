import XCTest
import RainSynth

final class RainSynthTests: XCTestCase {
    private struct Stats {
        var peak: Float = 0
        var sumSquares: Double = 0
        var count = 0
        var allFinite = true

        var rms: Float { count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0 }
    }

    /// Renders and returns the left and right channels mixed to mono.
    private func renderMono(_ synth: RainSynth, seconds: Double) -> [Float] {
        let frames = 512
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var output: [Float] = []
        var remaining = Int(seconds * synth.sampleRate)
        output.reserveCapacity(remaining)
        while remaining > 0 {
            let count = min(frames, remaining)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    synth.render(left: l.baseAddress!, right: r.baseAddress!, frameCount: count)
                }
            }
            for i in 0..<count {
                output.append((left[i] + right[i]) / 2)
            }
            remaining -= count
        }
        return output
    }

    private func render(_ synth: RainSynth, seconds: Double) -> Stats {
        let frames = 512
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var stats = Stats()
        var remaining = Int(seconds * synth.sampleRate)
        while remaining > 0 {
            let count = min(frames, remaining)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    synth.render(left: l.baseAddress!, right: r.baseAddress!, frameCount: count)
                }
            }
            for i in 0..<count {
                for sample in [left[i], right[i]] {
                    stats.allFinite = stats.allFinite && sample.isFinite
                    stats.peak = max(stats.peak, abs(sample))
                    stats.sumSquares += Double(sample * sample)
                    stats.count += 1
                }
            }
            remaining -= count
        }
        return stats
    }

    /// RMS of consecutive windows, after rolling off the lows the way hearing
    /// does at low volume. Deep rumble alone should not count as loud.
    private func levels(_ samples: [Float], sampleRate: Double, windowSeconds: Double) -> [Float] {
        let coefficient = Float(1 - exp(-2 * Double.pi * 200 / sampleRate))
        var low1: Float = 0
        var low2: Float = 0
        let window = Int(sampleRate * windowSeconds)
        var result: [Float] = []
        var sum: Float = 0
        for (index, sample) in samples.enumerated() {
            low1 += (sample - low1) * coefficient
            let high1 = sample - low1
            low2 += (high1 - low2) * coefficient
            let high = high1 - low2
            sum += high * high
            if (index + 1) % window == 0 {
                result.append((sum / Float(window)).squareRoot())
                sum = 0
            }
        }
        return result
    }

    private func loudestMoment(_ samples: [Float], sampleRate: Double) -> Float {
        levels(samples, sampleRate: sampleRate, windowSeconds: 0.4).max() ?? 0
    }

    /// How much the level drifts over seconds, in dB: the standard deviation
    /// of 2 second averages of the level.
    private func slowWander(_ samples: [Float], sampleRate: Double) -> Float {
        let decibels = levels(samples, sampleRate: sampleRate, windowSeconds: 0.25).map { 20 * log10($0) }
        let averages = (0...(decibels.count - 8)).map { decibels[$0..<($0 + 8)].reduce(0, +) / 8 }
        let mean = averages.reduce(0, +) / Float(averages.count)
        let variance = averages.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(averages.count)
        return variance.squareRoot()
    }

    func testPresetsAreAudibleFiniteAndNeverClip() {
        for preset in RainPreset.all {
            let settings = preset.apply(to: RainSettings(volume: 1))
            let synth = RainSynth(settings: settings, playing: true, seed: 7)
            _ = render(synth, seconds: 1)
            // Thunder presets strike within 2 to 5 seconds, so 10 covers one.
            let stats = render(synth, seconds: 10)
            XCTAssertTrue(stats.allFinite, preset.name)
            XCTAssertLessThanOrEqual(stats.peak, 1, preset.name)
            XCTAssertGreaterThan(stats.rms, 0.02, preset.name)
        }
    }

    func testMaxedOutSettingsStayWithinFullScale() {
        let settings = RainSettings(volume: 1, rain: 1, drops: 1, rumble: 1, tone: 1, wind: 1, thunder: 1)
        let stats = render(RainSynth(settings: settings, playing: true, seed: 3), seconds: 12)
        XCTAssertTrue(stats.allFinite)
        XCTAssertLessThanOrEqual(stats.peak, 1)
    }

    func testThunderIsClearlyLouderThanTheRain() {
        // Strikes vary in distance, so check several. Each 15 second render
        // contains at least one strike.
        let sampleRate = RainSynth.defaultSampleRate
        var decibels: [Float] = []
        for seed: UInt64 in 1...6 {
            var settings = RainPreset.storm.apply(to: RainSettings(volume: 0.5))
            let storm = renderMono(RainSynth(settings: settings, playing: true, seed: seed), seconds: 15)
            settings.thunder = 0
            let rain = renderMono(RainSynth(settings: settings, playing: true, seed: seed), seconds: 15)
            let ratio = loudestMoment(storm, sampleRate: sampleRate) / loudestMoment(rain, sampleRate: sampleRate)
            decibels.append(20 * log10(ratio))
        }
        let median = decibels.sorted()[decibels.count / 2]
        XCTAssertGreaterThan(median, 6, "thunder over the loudest rain, in dB: \(decibels)")
        XCTAssertGreaterThan(decibels.min()!, 3.5, "thunder over the loudest rain, in dB: \(decibels)")
    }

    func testRainIsSteadyWithoutWind() {
        let sampleRate = RainSynth.defaultSampleRate
        var settings = RainPreset.steady.apply(to: RainSettings(volume: 0.5))

        func wander(wind: Double) -> Float {
            settings.wind = wind
            let samples = renderMono(RainSynth(settings: settings, playing: true, seed: 4), seconds: 31)
            // Skip the fade-in.
            return slowWander(Array(samples.dropFirst(Int(sampleRate))), sampleRate: sampleRate)
        }

        let calm = wander(wind: 0)
        let windy = wander(wind: 1)
        XCTAssertLessThan(calm, 0.6, "calm rain drifts \(calm) dB")
        XCTAssertGreaterThan(windy, calm * 3, "wind drifts \(windy) dB, calm \(calm) dB")
    }

    func testPauseFadesToSilence() {
        let synth = RainSynth(settings: RainPreset.downpour.apply(to: RainSettings(volume: 1)), playing: true, seed: 11)
        XCTAssertGreaterThan(render(synth, seconds: 2).rms, 0.05)
        synth.setPlaying(false)
        _ = render(synth, seconds: 1)
        XCTAssertLessThan(render(synth, seconds: 0.5).peak, 0.001)
    }

    func testEverythingOffIsSilent() {
        let settings = RainSettings(volume: 1, rain: 0, drops: 0, rumble: 0, tone: 0.5, wind: 0, thunder: 0)
        let stats = render(RainSynth(settings: settings, playing: true, seed: 5), seconds: 3)
        XCTAssertEqual(stats.peak, 0)
    }

    func testPresetMatchingIgnoresVolume() {
        var settings = RainPreset.roof.apply(to: RainSettings(volume: 0.2))
        XCTAssertEqual(RainPreset.matching(settings)?.id, RainPreset.roof.id)
        settings.drops += 0.01
        XCTAssertNil(RainPreset.matching(settings))
    }
}
