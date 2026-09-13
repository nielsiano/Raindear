import XCTest
@testable import RainSynth

final class RainSynthTests: XCTestCase {
    private struct Stats {
        var peak: Float = 0
        var sumSquares: Double = 0
        var count = 0
        var allFinite = true

        var rms: Float { count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0 }
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

    func testPresetsAreAudibleFiniteAndNeverClip() {
        for preset in RainPreset.all {
            let settings = preset.apply(to: RainSettings(volume: 1))
            let synth = RainSynth(settings: settings, playing: true, seed: 7)
            _ = render(synth, seconds: 1)
            // Thunder presets strike within 3 to 8 seconds, so 10 covers one.
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
