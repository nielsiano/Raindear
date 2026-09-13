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

/// Output levels for each layer at full setting. Tuned with `rain-render`
/// against the spectrum and texture of real rain recordings. The rain sits
/// well below full scale so thunder has room to be louder than it.
private enum Level {
    static let bed: Float = 0.44
    static let patter: Float = 0.3
    static let drops: Float = 0.24
    static let rumble: Float = 0.28
    static let wind: Float = 2.5
    static let thunder: Float = 2
}

/// How much the rain intensity wanders. Swells, gusts and bursts come from
/// wind, so without wind they almost vanish and the rain stays steady.
/// Flutter is fast enough to be heard as texture rather than movement.
private enum Variation {
    static let calmSwell: Float = 0.03
    static let windySwell: Float = 0.25
    static let windyGust: Float = 0.6
    static let calmCluster: Float = 0.04
    static let windyCluster: Float = 0.15
    static let flutter: Float = 0.4
}

struct RainCore {
    static let voiceCount = 256
    /// Filters and modulation update every this many samples.
    static let controlInterval = 64
    /// How much of each ear's signal leaks into the other.
    static let crossfeed: Float = 0.3

    var settings = RainSettings()
    var playing = false

    private let sampleRate: Float
    private let controlRate: Float
    private var rng: Random
    private var controlCountdown = 0

    private let gainSmoothing: Float
    private let fadeSmoothing: Float
    private let toneSmoothing: Float
    private let swellSmoothing: Float
    private let gustSmoothing: Float
    private let clusterSmoothing: Float
    private let flutterSmoothing: Float
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
    private var clusterDrift = Drift()
    private var flutterDrift = Drift()
    private var sweepDriftL = Drift()
    private var sweepDriftR = Drift()

    // Rain bus: the floor and drops, then the tone filter.
    private let bedHighpass: Float
    private var bedLowL: Float = 0
    private var bedLowR: Float = 0
    private var toneCoefficient1: Float = 1
    private var toneCoefficient2: Float = 1
    private var toneL1: Float = 0
    private var toneL2: Float = 0
    private var toneR1: Float = 0
    private var toneR2: Float = 0

    // Drops. Active voices are packed at the front of `voices`.
    private let voices: UnsafeMutablePointer<DropVoice>
    private var activeVoices = 0
    private var stealIndex = 0
    private var patterChance: Float = 0
    private var patterLevel: Float = 0
    /// Close drops per sample, and how far until the next one, in units of
    /// the average gap.
    private var dropRate: Float = 0
    private var dropCountdown: Float = 1
    private var dropIrregularity: Float = 0
    /// Alternates which side of center the next drop lands on.
    private var nextDropOnLeft = false

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

    // Thunder.
    private var thunder: Thunder
    private var thunderEnabled = false
    private var thunderCountdown = 0

    // Output.
    private var crossL: Float = 0
    private var crossR: Float = 0
    private var limiter: Limiter

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
        clusterSmoothing = smoothing(0.08, rate: controlRate)
        flutterSmoothing = smoothing(0.015, rate: controlRate)
        sweepSmoothing = smoothing(1.5, rate: controlRate)
        crossfeedSmoothing = onePoleCoefficient(700, sampleRate: sampleRate)
        // Recordings of rain fall off about 7 dB per octave below 1 kHz.
        bedHighpass = onePoleCoefficient(600, sampleRate: sampleRate)
        rumbleHighpass = .highpass(40, q: 0.7, sampleRate: sampleRate)
        thunder = Thunder(sampleRate: sampleRate)
        limiter = Limiter(threshold: 0.8, sampleRate: sampleRate)
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

            if rng.unit() < patterChance { spawnPatter() }
            if dropRate > 0 {
                dropCountdown -= dropRate
                if dropCountdown <= 0 {
                    spawnDrop()
                    dropCountdown += nextDropGap()
                }
            }

            let whiteL = rng.bipolar()
            let whiteR = rng.bipolar()
            bedLowL += (whiteL - bedLowL) * bedHighpass
            bedLowR += (whiteR - bedLowR) * bedHighpass
            var rainL = (whiteL - bedLowL) * bedGain
            var rainR = (whiteR - bedLowR) * bedGain

            var index = 0
            while index < activeVoices {
                let sample = voices[index].process(rng.bipolar())
                rainL += sample * voices[index].gainL
                rainR += sample * voices[index].gainR
                if voices[index].isFinished {
                    activeVoices -= 1
                    voices[index] = voices[activeVoices]
                } else {
                    index += 1
                }
            }

            toneL1 += (rainL - toneL1) * toneCoefficient1
            toneL2 += (toneL1 - toneL2) * toneCoefficient2
            toneR1 += (rainR - toneR1) * toneCoefficient1
            toneR2 += (toneR1 - toneR2) * toneCoefficient2

            brownL = brownL * 0.995 + rng.bipolar() * 0.07
            brownR = brownR * 0.995 + rng.bipolar() * 0.07
            let rumbleL = rumbleLowpassL.process(rumbleHighpassL.process(brownL, rumbleHighpass), rumbleLowpass) * rumbleGain
            let rumbleR = rumbleLowpassR.process(rumbleHighpassR.process(brownR, rumbleHighpass), rumbleLowpass) * rumbleGain

            let windL = windStateL.process(windPinkL.process(rng.bipolar()), windBandL) * windGain
            let windR = windStateR.process(windPinkR.process(rng.bipolar()), windBandR) * windGain

            let (thunderL, thunderR) = thunder.process(&rng)

            let dryL = toneL2 + rumbleL + windL + thunderL
            let dryR = toneR2 + rumbleR + windR + thunderR
            // On headphones, fully separated channels sound like they are inside
            // your head. Feed a little low-passed signal from the other ear, as
            // happens naturally with sound in a room.
            crossL += (dryR - crossL) * crossfeedSmoothing
            crossR += (dryL - crossR) * crossfeedSmoothing

            let outL = (dryL + Self.crossfeed * crossL) * master
            let outR = (dryR + Self.crossfeed * crossR) * master
            let gain = limiter.gain(forPeak: max(abs(outL), abs(outR)))
            left[i] = softClip(outL * gain)
            right[i] = softClip(outR * gain)
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

        // Rain flutters on its own. With wind it also swells over seconds,
        // surges with gusts, and comes in bursts of heavier drops.
        let swell = swellDrift.tick(&rng, minTicks: ticks(6), maxTicks: ticks(14), coefficient: swellSmoothing)
        let gust = gustDrift.tick(&rng, minTicks: ticks(1.5), maxTicks: ticks(5), coefficient: gustSmoothing)
        let cluster = clusterDrift.tick(&rng, minTicks: ticks(0.15), maxTicks: ticks(0.7), coefficient: clusterSmoothing)
        let flutter = flutterDrift.tick(&rng, minTicks: ticks(0.03), maxTicks: ticks(0.12), coefficient: flutterSmoothing)
        let surge = exp(
            (Variation.calmSwell + Variation.windySwell * wind) * swell
                + Variation.windyGust * wind * gust
                + (Variation.calmCluster + Variation.windyCluster * wind) * cluster
                + Variation.flutter * flutter
        )

        let rainCurve = pow(rain, 1.3)
        bedTarget = rainCurve * Level.bed * surge
        patterLevel = rainCurve * Level.patter
        // Bursts bring more drops, not just louder ones.
        patterChance = rain > 0 ? min((120 + 1400 * rain) * surge * surge / sampleRate, 0.5) : 0
        dropRate = drops > 0 ? (2 + 100 * drops * drops) * surge / sampleRate : 0
        dropIrregularity = wind
        rumbleTarget = pow(rumble, 1.3) * Level.rumble * surge.squareRoot()
        let gustShape = 0.5 + 0.5 * gust
        windTarget = pow(wind, 1.3) * Level.wind * (0.2 + 1.5 * gustShape * gustShape)

        // Gentle two-pole roll-off: about -8 dB at 8 kHz in the middle of the range,
        // like a recording, instead of a hard ceiling.
        let toneCutoff = 1200 * pow(12, tone)
        toneCoefficient1 = onePoleCoefficient(toneCutoff, sampleRate: sampleRate)
        toneCoefficient2 = onePoleCoefficient(toneCutoff * 2.5, sampleRate: sampleRate)
        rumbleLowpass = .lowpass(220 + 200 * tone, q: 0.7, sampleRate: sampleRate)

        let sweepL = sweepDriftL.tick(&rng, minTicks: ticks(3), maxTicks: ticks(8), coefficient: sweepSmoothing)
        let sweepR = sweepDriftR.tick(&rng, minTicks: ticks(3), maxTicks: ticks(8), coefficient: sweepSmoothing)
        windBandL = .bandpass(350 * pow(2, 1.3 * sweepL + 0.5 * gust), q: 1.2, sampleRate: sampleRate)
        windBandR = .bandpass(350 * pow(2, 1.3 * sweepR + 0.5 * gust), q: 1.2, sampleRate: sampleRate)

        scheduleThunder(thunderAmount)
        thunder.updateControl(&rng, interval: Self.controlInterval, controlRate: controlRate, sampleRate: sampleRate)
    }

    private mutating func scheduleThunder(_ amount: Float) {
        let enabled = amount > 0
        if enabled && !thunderEnabled {
            // Turning thunder on should be audible soon, not in a minute.
            thunderCountdown = Int(rng.range(2, 5) * sampleRate)
        }
        thunderEnabled = enabled
        guard enabled else { return }

        thunderCountdown -= Self.controlInterval
        if thunderCountdown <= 0 {
            thunder.strike(strength: Level.thunder * (0.75 + 0.25 * amount), rng: &rng, sampleRate: sampleRate)
            let meanGap = 90 - 78 * amount
            let gap = max(6, -log(max(rng.unit(), 0.0001)) * meanGap)
            thunderCountdown = Int(gap * sampleRate)
        }
    }

    /// Distant drops: hundreds to thousands of quiet, very short, unpitched ticks
    /// per second. Together they make the floor sound like rain instead of static.
    private mutating func spawnPatter() {
        addVoice(DropVoice(
            attackTime: rng.range(0.00005, 0.0003),
            decayTime: rng.logRange(0.0004, 0.003),
            highpass: rng.logRange(700, 2500),
            lowpass: rng.logRange(2000, 12000),
            amplitude: patterLevel * loudness(spread: 0.5, limit: 2.5),
            pan: nextPan(width: 0.9),
            sampleRate: sampleRate
        ))
    }

    /// Close drops: a short tick plus a softer, darker body, like a drop
    /// landing on a leaf or the ground nearby.
    private mutating func spawnDrop() {
        let amplitude = Level.drops * loudness(spread: 0.55, limit: 2.5)
        // A loud drop right at one ear is distracting on headphones.
        let pan = nextPan(width: 0.6)
        addVoice(DropVoice(
            attackTime: rng.range(0.0001, 0.0004),
            decayTime: rng.logRange(0.0008, 0.004),
            highpass: rng.logRange(200, 1000),
            lowpass: rng.logRange(2000, 8000),
            amplitude: amplitude,
            pan: pan,
            sampleRate: sampleRate
        ))
        addVoice(DropVoice(
            attackTime: rng.range(0.0015, 0.004),
            decayTime: rng.logRange(0.008, 0.03),
            highpass: rng.logRange(90, 250),
            lowpass: rng.logRange(500, 2200),
            amplitude: amplitude * rng.range(0.2, 0.5),
            // Low sounds are hard to place anyway, and moving them around
            // makes the rain seem to drift between the ears.
            pan: 0.5 + (pan - 0.5) * 0.4,
            sampleRate: sampleRate
        ))
    }

    /// Gap to the next close drop, as a multiple of the average gap. Without
    /// wind, drops are spread fairly evenly so they do not bunch up and leave
    /// holes. Gusts shake drops loose in bursts, so wind makes the timing
    /// fully random.
    private mutating func nextDropGap() -> Float {
        let even = rng.range(0.4, 1.6)
        let random = -log(max(rng.unit(), 0.0001))
        return even + (random - even) * dropIrregularity
    }

    /// A random position that alternates sides of center. Each drop still
    /// lands somewhere different, but neither ear gets more drops than the
    /// other for long, so light rain does not drift from side to side.
    private mutating func nextPan(width: Float) -> Float {
        nextDropOnLeft.toggle()
        let offset = rng.unit() * width / 2
        return nextDropOnLeft ? 0.5 - offset : 0.5 + offset
    }

    /// Random loudness around 1: most drops are similar, a few are louder,
    /// and none is so loud that it jumps out.
    private mutating func loudness(spread: Float, limit: Float) -> Float {
        min(exp(spread * rng.gaussian()), limit)
    }

    private mutating func addVoice(_ voice: DropVoice) {
        if activeVoices < Self.voiceCount {
            voices[activeVoices] = voice
            activeVoices += 1
        } else {
            voices[stealIndex] = voice
            stealIndex = (stealIndex + 1) % Self.voiceCount
        }
    }

    private func ticks(_ seconds: Float) -> Int {
        max(1, Int(seconds * controlRate))
    }

    private func unitValue(_ value: Double) -> Float {
        value.isFinite ? Float(min(max(value, 0), 1)) : 0
    }
}

/// One drop: filtered noise shaped by an envelope with a rounded attack.
struct DropVoice {
    private(set) var gainL: Float = 0
    private(set) var gainR: Float = 0
    private var amplitude: Float = 0
    private var attack: Float = 1
    private var decay: Float = 0
    private var attackMultiplier: Float = 0
    private var decayMultiplier: Float = 0
    private var highpassCoefficient: Float = 0
    private var lowpassCoefficient: Float = 1
    private var highpassState: Float = 0
    private var lowpassState1: Float = 0
    private var lowpassState2: Float = 0

    init() {}

    init(
        attackTime: Float,
        decayTime: Float,
        highpass: Float,
        lowpass: Float,
        amplitude: Float,
        pan: Float,
        sampleRate: Float
    ) {
        let attackSamples = max(attackTime * sampleRate, 0.5)
        let decaySamples = max(decayTime * sampleRate, attackSamples * 2.5)
        attackMultiplier = exp(-1 / attackSamples)
        decayMultiplier = exp(-1 / decaySamples)
        attack = 1
        decay = 1

        // The envelope is decay minus attack, which starts at zero and rises
        // smoothly. Scale it so it peaks at 1.
        let peakTime = attackSamples * decaySamples / (decaySamples - attackSamples) * log(decaySamples / attackSamples)
        let envelopePeak = exp(-peakTime / decaySamples) - exp(-peakTime / attackSamples)

        highpassCoefficient = onePoleCoefficient(highpass, sampleRate: sampleRate)
        lowpassCoefficient = onePoleCoefficient(lowpass, sampleRate: sampleRate)
        // Two one-pole low-passes remove noise power. Put it back, so a dark
        // drop is not automatically a quiet one.
        let c = lowpassCoefficient
        let r2 = (1 - c) * (1 - c)
        let noisePower = c * c * c * c * (1 + r2) / pow(1 - r2, 3)

        self.amplitude = amplitude / (envelopePeak * noisePower.squareRoot())
        gainL = cos(pan * .pi / 2)
        gainR = sin(pan * .pi / 2)
    }

    var isFinished: Bool {
        decay < 0.003
    }

    @inline(__always)
    mutating func process(_ white: Float) -> Float {
        highpassState += (white - highpassState) * highpassCoefficient
        lowpassState1 += (white - highpassState - lowpassState1) * lowpassCoefficient
        lowpassState2 += (lowpassState1 - lowpassState2) * lowpassCoefficient
        attack *= attackMultiplier
        decay *= decayMultiplier
        return lowpassState2 * (decay - attack) * amplitude
    }
}

/// Thunder: a strike is a few claps over several seconds that pile onto one
/// envelope, with a low-pass that opens on each clap and closes as it rolls
/// away. Distant strikes are quieter, darker and slower to build.
struct Thunder {
    private static let bodyGain: Float = 4
    private static let rumbleGain: Float = 0.35

    private var active = false
    private var distance: Float = 0
    private var strength: Float = 0
    private var clapIndex = 0
    private var clapCount = 0
    private var clapCountdown = 0
    private var envelope: Float = 0
    private var target: Float = 0
    private var attackSmoothing: Float = 0
    private var attackSamplesLeft = 0
    private var decayMultiplier: Float = 1
    private var cutoff: Float = 400
    private var cutoffFloor: Float = 400
    private var bodyCoefficient: Float = 0
    private var body1: Float = 0
    private var body2: Float = 0
    private var pink = PinkNoise()
    private var brown: Float = 0
    private var rumble1: Float = 0
    private var rumble2: Float = 0
    private let rumbleCoefficient: Float
    private var crackle: Float = 0
    private var crackleMultiplier: Float = 0
    private var crackleState: Float = 0
    private let crackleCoefficient: Float
    private let highpass: BiquadCoefficients
    private var highpassState = BiquadState()
    private let bodyHighpass: BiquadCoefficients
    private var bodyHighpassState = BiquadState()
    private var textureDrift = Drift()
    private var texture: Float = 1
    private var gainL: Float = 0
    private var gainR: Float = 0

    init(sampleRate: Float) {
        rumbleCoefficient = onePoleCoefficient(120, sampleRate: sampleRate)
        crackleCoefficient = onePoleCoefficient(3500, sampleRate: sampleRate)
        highpass = .highpass(45, q: 0.7, sampleRate: sampleRate)
        // Sub-bass uses up headroom without making thunder sound louder,
        // so most of it comes from the separate, quieter rumble.
        bodyHighpass = .highpass(150, q: 0.7, sampleRate: sampleRate)
    }

    mutating func strike(strength: Float, rng: inout Random, sampleRate: Float) {
        distance = rng.unit()
        self.strength = strength * (1 - 0.4 * distance)
        clapIndex = 0
        clapCount = 2 + Int(rng.unit() * 5)
        clapCountdown = 0
        // Keep most of the energy where ears are sensitive at low volume.
        cutoffFloor = 750 - 400 * distance
        if distance < 0.35 {
            // Close strikes start with a crack.
            crackle = self.strength * (0.35 - distance) * 3
            crackleMultiplier = exp(-1 / (rng.range(0.05, 0.15) * sampleRate))
        }
        let pan = rng.range(0.2, 0.8) * .pi / 2
        gainL = cos(pan)
        gainR = sin(pan)
        active = true
    }

    mutating func updateControl(_ rng: inout Random, interval: Int, controlRate: Float, sampleRate: Float) {
        guard active else { return }
        if clapIndex < clapCount {
            clapCountdown -= interval
            if clapCountdown <= 0 {
                clap(&rng, sampleRate: sampleRate)
            }
        } else if envelope < 0.0005 && attackSamplesLeft <= 0 {
            active = false
            return
        }
        cutoff += (cutoffFloor - cutoff) * smoothing(0.7, rate: controlRate)
        bodyCoefficient = onePoleCoefficient(cutoff, sampleRate: sampleRate)
        let value = textureDrift.tick(
            &rng,
            minTicks: Int(0.02 * controlRate),
            maxTicks: Int(0.12 * controlRate),
            coefficient: smoothing(0.02, rate: controlRate)
        )
        texture = 0.8 + 0.35 * value
    }

    private mutating func clap(_ rng: inout Random, sampleRate: Float) {
        let fade = pow(0.8, Float(clapIndex))
        let loudness = strength * rng.range(0.5, 1) * fade
        target = min(envelope + loudness, strength * 1.2)
        let attackTime = (0.03 + 0.3 * distance) * rng.range(0.6, 1.4)
        attackSmoothing = smoothing(attackTime, rate: sampleRate)
        attackSamplesLeft = Int(attackTime * 3 * sampleRate)
        decayMultiplier = exp(-1 / (rng.range(0.9, 2.2) * sampleRate))
        cutoff = max(cutoff, (3500 - 2300 * distance) * rng.range(0.6, 1) * fade)
        clapIndex += 1
        clapCountdown = Int(rng.range(0.25, 1.4) * sampleRate)
    }

    @inline(__always)
    mutating func process(_ rng: inout Random) -> (Float, Float) {
        guard active else { return (0, 0) }
        if attackSamplesLeft > 0 {
            envelope += (target - envelope) * attackSmoothing
            attackSamplesLeft -= 1
        } else {
            envelope *= decayMultiplier
        }
        let white = rng.bipolar()
        let pinkNoise = bodyHighpassState.process(pink.process(white), bodyHighpass)
        body1 += (pinkNoise - body1) * bodyCoefficient
        body2 += (body1 - body2) * bodyCoefficient
        brown = brown * 0.998 + white * 0.05
        rumble1 += (brown - rumble1) * rumbleCoefficient
        rumble2 += (rumble1 - rumble2) * rumbleCoefficient
        crackleState += (white * crackle - crackleState) * crackleCoefficient
        crackle *= crackleMultiplier

        let low = highpassState.process(body2 * Self.bodyGain + rumble2 * Self.rumbleGain, highpass)
        let output = low * envelope * texture + crackleState
        return (output * gainL, output * gainR)
    }
}
