import Foundation
import os

/// Procedural rain generator.
///
/// Settings can be changed from any thread. `render` is meant for the audio
/// thread: it does not allocate and never waits on a lock.
public final class RainSynth: @unchecked Sendable {
    public static let defaultSampleRate: Double = 48_000

    public let sampleRate: Double

    private let core: UnsafeMutablePointer<RainCore>
    private let voices: UnsafeMutablePointer<DropVoice>
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>

    // Guarded by `lock`.
    private var pendingSettings: RainSettings
    private var pendingPlaying: Bool
    private var hasPending = true

    public init(
        settings: RainSettings,
        playing: Bool = false,
        sampleRate: Double = RainSynth.defaultSampleRate,
        seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) {
        self.sampleRate = sampleRate
        pendingSettings = settings
        pendingPlaying = playing

        voices = .allocate(capacity: RainCore.voiceCount)
        voices.initialize(repeating: DropVoice(), count: RainCore.voiceCount)
        core = .allocate(capacity: 1)
        core.initialize(to: RainCore(sampleRate: Float(sampleRate), seed: seed, voices: voices))
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        core.deinitialize(count: 1)
        core.deallocate()
        voices.deinitialize(count: RainCore.voiceCount)
        voices.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    public func setSettings(_ settings: RainSettings) {
        os_unfair_lock_lock(lock)
        pendingSettings = settings
        hasPending = true
        os_unfair_lock_unlock(lock)
    }

    /// Fades in or out rather than cutting off.
    public func setPlaying(_ playing: Bool) {
        os_unfair_lock_lock(lock)
        pendingPlaying = playing
        hasPending = true
        os_unfair_lock_unlock(lock)
    }

    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        // If the main thread holds the lock right now, keep the previous
        // settings for this buffer instead of blocking the audio thread.
        if os_unfair_lock_trylock(lock) {
            if hasPending {
                core.pointee.settings = pendingSettings
                core.pointee.playing = pendingPlaying
                hasPending = false
            }
            os_unfair_lock_unlock(lock)
        }
        core.pointee.render(left: left, right: right, frameCount: frameCount)
    }
}

/// Output levels for each layer at full setting. Tuned by ear and with `rain-render`.
private enum Level {
    static let bed: Float = 3.3
    static let micro: Float = 0.45
    static let drops: Float = 0.5
    static let rumble: Float = 0.85
    static let wind: Float = 4
    static let thunder: Float = 2
}

struct RainCore {
    static let voiceCount = 96
    /// Filters and modulation update every this many samples.
    static let controlInterval = 64
    /// How much of each ear's signal leaks into the other.
    static let crossfeed: Float = 0.3

    var settings = RainSettings()
    var playing = false

    private let sampleRate: Float
    private let controlRate: Float
    private let voices: UnsafeMutablePointer<DropVoice>
    private var rng: Random
    private var controlCountdown = 0

    private let gainSmoothing: Float
    private let fadeSmoothing: Float
    private let toneSmoothing: Float
    private let swellSmoothing: Float
    private let gustSmoothing: Float
    private let sweepSmoothing: Float
    private let crossfeedSmoothing: Float

    // Per-sample smoothed gains and their control-rate targets.
    private var master: Float = 0
    private var masterTarget: Float = 0
    private var bedGain: Float = 0
    private var bedTarget: Float = 0
    private var rumbleGain: Float = 0
    private var rumbleTarget: Float = 0
    private var windGain: Float = 0
    private var windTarget: Float = 0

    // Slow modulation.
    private var tone: Float = 0.5
    private var swellDrift = Drift()
    private var gustDrift = Drift()
    private var sweepDriftL = Drift()
    private var sweepDriftR = Drift()

    // Rain bus: hiss and drops, then the tone filter.
    private var bedPinkL = PinkNoise()
    private var bedPinkR = PinkNoise()
    private var bedHighpass = BiquadCoefficients()
    private var bedHighpassL = BiquadState()
    private var bedHighpassR = BiquadState()
    // Two biquads with these Qs make a flat 4th-order Butterworth low-pass.
    private var toneFilterA = BiquadCoefficients()
    private var toneFilterB = BiquadCoefficients()
    private var toneL1 = BiquadState()
    private var toneL2 = BiquadState()
    private var toneR1 = BiquadState()
    private var toneR2 = BiquadState()

    // Drops.
    private var nextVoice = 0
    private var microChance: Float = 0
    private var microLevel: Float = 0
    private var dropChance: Float = 0

    // Rumble.
    private var brownL: Float = 0
    private var brownR: Float = 0
    private let rumbleHighpass: BiquadCoefficients
    private var rumbleLowpass = BiquadCoefficients()
    private var rumbleHighpassL = BiquadState()
    private var rumbleHighpassR = BiquadState()
    private var rumbleLowpassL = BiquadState()
    private var rumbleLowpassR = BiquadState()

    // Wind.
    private var windPinkL = PinkNoise()
    private var windPinkR = PinkNoise()
    private var windBandL = BiquadCoefficients()
    private var windBandR = BiquadCoefficients()
    private var windStateL = BiquadState()
    private var windStateR = BiquadState()

    // Headphone crossfeed.
    private var crossL: Float = 0
    private var crossR: Float = 0

    // Thunder.
    private var thunder = Thunder()
    private var thunderEnabled = false
    private var thunderCountdown = 0

    init(sampleRate: Float, seed: UInt64, voices: UnsafeMutablePointer<DropVoice>) {
        self.sampleRate = sampleRate
        self.voices = voices
        controlRate = sampleRate / Float(Self.controlInterval)
        rng = Random(seed: seed)
        gainSmoothing = smoothing(0.05, rate: sampleRate)
        fadeSmoothing = smoothing(0.1, rate: sampleRate)
        toneSmoothing = smoothing(0.08, rate: controlRate)
        swellSmoothing = smoothing(2.5, rate: controlRate)
        gustSmoothing = smoothing(0.7, rate: controlRate)
        sweepSmoothing = smoothing(1.5, rate: controlRate)
        crossfeedSmoothing = smoothing(1 / (2 * .pi * 700), rate: sampleRate)
        rumbleHighpass = .highpass(40, q: 0.7, sampleRate: sampleRate)
    }

    mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount {
            if controlCountdown <= 0 {
                updateControl()
                controlCountdown = Self.controlInterval
            }
            controlCountdown -= 1

            master += (masterTarget - master) * fadeSmoothing
            bedGain += (bedTarget - bedGain) * gainSmoothing
            rumbleGain += (rumbleTarget - rumbleGain) * gainSmoothing
            windGain += (windTarget - windGain) * gainSmoothing

            if rng.unit() < microChance { spawnDrop(close: false) }
            if rng.unit() < dropChance { spawnDrop(close: true) }

            var rainL = bedHighpassL.process(bedPinkL.process(rng.bipolar()), bedHighpass) * bedGain
            var rainR = bedHighpassR.process(bedPinkR.process(rng.bipolar()), bedHighpass) * bedGain
            for index in 0..<Self.voiceCount where voices[index].active {
                let sample = voices[index].process(&rng)
                rainL += sample * voices[index].gainL
                rainR += sample * voices[index].gainR
            }
            rainL = toneL2.process(toneL1.process(rainL, toneFilterA), toneFilterB)
            rainR = toneR2.process(toneR1.process(rainR, toneFilterA), toneFilterB)

            brownL = brownL * 0.995 + rng.bipolar() * 0.07
            brownR = brownR * 0.995 + rng.bipolar() * 0.07
            let rumbleL = rumbleLowpassL.process(rumbleHighpassL.process(brownL, rumbleHighpass), rumbleLowpass) * rumbleGain
            let rumbleR = rumbleLowpassR.process(rumbleHighpassR.process(brownR, rumbleHighpass), rumbleLowpass) * rumbleGain

            let windL = windStateL.process(windPinkL.process(rng.bipolar()), windBandL) * windGain
            let windR = windStateR.process(windPinkR.process(rng.bipolar()), windBandR) * windGain

            let (thunderL, thunderR) = thunder.process(&rng)

            let dryL = rainL + rumbleL + windL + thunderL
            let dryR = rainR + rumbleR + windR + thunderR
            // On headphones, fully separated channels sound like they are inside
            // your head. Feed a little low-passed signal from the other ear, as
            // happens naturally with sound in a room.
            crossL += (dryR - crossL) * crossfeedSmoothing
            crossR += (dryL - crossR) * crossfeedSmoothing

            left[i] = softClip((dryL + Self.crossfeed * crossL) * master)
            right[i] = softClip((dryR + Self.crossfeed * crossR) * master)
        }
    }

    private mutating func updateControl() {
        let volume = unitValue(settings.volume)
        let rain = unitValue(settings.rain)
        let drops = unitValue(settings.drops)
        let rumble = unitValue(settings.rumble)
        let wind = unitValue(settings.wind)
        let thunderAmount = unitValue(settings.thunder)

        masterTarget = playing ? volume * volume : 0
        tone += (unitValue(settings.tone) - tone) * toneSmoothing

        let swell = swellDrift.tick(&rng, minTicks: ticks(6), maxTicks: ticks(14), coefficient: swellSmoothing)
        let gust = gustDrift.tick(&rng, minTicks: ticks(1.5), maxTicks: ticks(5), coefficient: gustSmoothing)
        // Rain gets heavier and lighter on its own, and surges with the wind.
        let surge = max(0.2, 1 + 0.12 * swell + (0.05 + 0.45 * wind) * gust)

        let rainCurve = pow(rain, 1.3)
        bedTarget = rainCurve * Level.bed * surge
        microLevel = rainCurve * Level.micro * surge
        microChance = rain > 0 ? (200 + 1800 * rain) * surge / sampleRate : 0
        dropChance = pow(drops, 1.6) * 250 * surge / sampleRate
        rumbleTarget = pow(rumble, 1.3) * Level.rumble * surge
        let gustShape = 0.5 + 0.5 * gust
        windTarget = pow(wind, 1.3) * Level.wind * (0.2 + 1.5 * gustShape * gustShape)

        let toneCutoff = 900 * pow(20, tone)
        toneFilterA = .lowpass(toneCutoff, q: 0.5412, sampleRate: sampleRate)
        toneFilterB = .lowpass(toneCutoff, q: 1.3066, sampleRate: sampleRate)
        bedHighpass = .highpass(140 + 260 * tone, q: 0.6, sampleRate: sampleRate)
        rumbleLowpass = .lowpass(220 + 200 * tone, q: 0.7, sampleRate: sampleRate)

        let sweepL = sweepDriftL.tick(&rng, minTicks: ticks(3), maxTicks: ticks(8), coefficient: sweepSmoothing)
        let sweepR = sweepDriftR.tick(&rng, minTicks: ticks(3), maxTicks: ticks(8), coefficient: sweepSmoothing)
        windBandL = .bandpass(350 * pow(2, 1.3 * sweepL + 0.5 * gust), q: 1.2, sampleRate: sampleRate)
        windBandR = .bandpass(350 * pow(2, 1.3 * sweepR + 0.5 * gust), q: 1.2, sampleRate: sampleRate)

        scheduleThunder(thunderAmount)
        thunder.updateControl(&rng, controlRate: controlRate, sampleRate: sampleRate)
    }

    private mutating func scheduleThunder(_ amount: Float) {
        let enabled = amount > 0
        if enabled && !thunderEnabled {
            // Turning thunder on should be audible soon, not in two minutes.
            thunderCountdown = Int(rng.range(3, 8) * sampleRate)
        }
        thunderEnabled = enabled
        guard enabled else { return }

        thunderCountdown -= Self.controlInterval
        if thunderCountdown <= 0 {
            thunder.strike(loudness: Level.thunder * (0.7 + 0.3 * amount), rng: &rng, sampleRate: sampleRate)
            let meanGap = 120 - 100 * amount
            let gap = max(8, -log(max(rng.unit(), 0.0001)) * meanGap)
            thunderCountdown = Int(gap * sampleRate)
        }
    }

    /// Close drops are sparse, louder and varied. Distant ones are the dense,
    /// quiet patter that makes the hiss sound like rain instead of static.
    private mutating func spawnDrop(close: Bool) {
        var voice = DropVoice()
        let frequency: Float
        let q: Float
        let burstTime: Float
        let level: Float
        let width: Float

        if close {
            let loudness = pow(rng.unit(), 2)
            level = Level.drops * (0.2 + 0.8 * loudness)
            frequency = rng.logRange(600, 4000) * (0.7 + 0.6 * tone)
            q = rng.range(1.5, 5)
            burstTime = rng.range(0.0012, 0.004)
            // A loud drop right at one ear is distracting on headphones.
            width = 0.6
            if rng.unit() < 0.05 {
                // A drop landing in a puddle: a short sine that glides upward.
                voice.bubbleAmplitude = 0.3 * (0.3 + 0.7 * loudness)
                voice.bubbleStep = rng.range(900, 2400) / sampleRate
                voice.bubbleGlide = pow(1.8, 1 / (0.04 * sampleRate))
                voice.bubbleDecay = exp(-1 / (rng.range(0.012, 0.03) * sampleRate))
            }
        } else {
            level = microLevel * (0.15 + 0.85 * pow(rng.unit(), 3))
            frequency = rng.logRange(1500, 7000) * (0.7 + 0.6 * tone)
            q = rng.range(0.8, 2.5)
            burstTime = rng.range(0.0003, 0.0015)
            width = 0.85
        }

        voice.active = true
        voice.filter = .bandpass(frequency, q: q, sampleRate: sampleRate)
        // A narrow band-pass removes most of the noise energy; make it up.
        voice.drive = min((sampleRate * q / (.pi * frequency)).squareRoot(), 8)
        voice.burst = 1
        voice.burstDecay = exp(-1 / (burstTime * sampleRate))
        let pan = (0.5 + width * (rng.unit() - 0.5)) * .pi / 2
        voice.gainL = cos(pan) * level
        voice.gainR = sin(pan) * level

        voices[nextVoice] = voice
        nextVoice = (nextVoice + 1) % Self.voiceCount
    }

    private func ticks(_ seconds: Float) -> Int {
        Int(seconds * controlRate)
    }

    private func unitValue(_ value: Double) -> Float {
        value.isFinite ? Float(min(max(value, 0), 1)) : 0
    }
}

struct DropVoice {
    var active = false
    var gainL: Float = 0
    var gainR: Float = 0
    var filter = BiquadCoefficients()
    var drive: Float = 1
    var burst: Float = 0
    var burstDecay: Float = 0
    var bubbleAmplitude: Float = 0
    var bubbleDecay: Float = 0
    var bubblePhase: Float = 0
    var bubbleStep: Float = 0
    var bubbleGlide: Float = 1
    private var state = BiquadState()

    @inline(__always)
    mutating func process(_ rng: inout Random) -> Float {
        var output = state.process(rng.bipolar() * burst * drive, filter)
        burst *= burstDecay
        if bubbleAmplitude > 0.0001 {
            output += sin(2 * .pi * bubblePhase) * bubbleAmplitude
            bubblePhase += bubbleStep
            if bubblePhase >= 1 { bubblePhase -= 1 }
            bubbleStep *= bubbleGlide
            bubbleAmplitude *= bubbleDecay
        }
        if burst < 0.001 && bubbleAmplitude <= 0.0001 {
            active = false
        }
        return output
    }
}

/// One thunder voice. A new strike picks up from the current envelope, so
/// overlapping strikes do not click.
struct Thunder {
    private var active = false
    private var attacking = false
    private var envelope: Float = 0
    private var peak: Float = 0
    private var attackCoefficient: Float = 0
    private var decayCoefficient: Float = 0
    private var crackle: Float = 0
    private var crackleDecay: Float = 0
    private var brown: Float = 0
    private var cutoff: Float = 200
    private var lowpass = BiquadCoefficients()
    private var highpass = BiquadCoefficients()
    private var lowpassA = BiquadState()
    private var lowpassB = BiquadState()
    private var highpassState = BiquadState()
    private var rollDrift = Drift()
    private var roll: Float = 1
    private var gainL: Float = 0
    private var gainR: Float = 0

    mutating func strike(loudness: Float, rng: inout Random, sampleRate: Float) {
        // Far-away thunder is quieter, darker, and swells in slowly.
        let distance = rng.unit()
        active = true
        attacking = true
        peak = loudness * (1 - 0.6 * distance)
        // Even close strikes take a moment to build, so they do not startle.
        attackCoefficient = smoothing(0.06 + 0.5 * distance, rate: sampleRate)
        decayCoefficient = exp(-1 / ((rng.range(1.5, 3.5) + 2 * distance) * sampleRate))
        crackle = (1 - distance) * (1 - distance) * 1.5
        crackleDecay = exp(-1 / (0.3 * sampleRate))
        cutoff = 1800 - 1200 * distance
        highpass = .highpass(35, q: 0.7, sampleRate: sampleRate)
        let pan = (0.25 + 0.5 * rng.unit()) * .pi / 2
        gainL = cos(pan)
        gainR = sin(pan)
    }

    mutating func updateControl(_ rng: inout Random, controlRate: Float, sampleRate: Float) {
        guard active else { return }
        cutoff += (120 - cutoff) * smoothing(1, rate: controlRate)
        lowpass = .lowpass(cutoff, q: 0.7, sampleRate: sampleRate)
        let value = rollDrift.tick(
            &rng,
            minTicks: Int(0.12 * controlRate),
            maxTicks: Int(0.6 * controlRate),
            coefficient: smoothing(0.06, rate: controlRate)
        )
        roll = max(0.15, 0.6 + 0.7 * value)
    }

    @inline(__always)
    mutating func process(_ rng: inout Random) -> (Float, Float) {
        guard active else { return (0, 0) }
        if attacking {
            envelope += (peak * 1.05 - envelope) * attackCoefficient
            if envelope >= peak { attacking = false }
        } else {
            envelope *= decayCoefficient
            if envelope < 0.0005 { active = false }
        }
        let white = rng.bipolar()
        brown = brown * 0.997 + white * 0.08
        let excitation = brown + white * crackle
        crackle *= crackleDecay
        let filtered = lowpassB.process(lowpassA.process(excitation, lowpass), lowpass)
        let output = highpassState.process(filtered, highpass) * envelope * roll
        return (output * gainL, output * gainR)
    }
}
