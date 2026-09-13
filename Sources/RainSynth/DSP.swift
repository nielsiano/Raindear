import Foundation

/// xorshift64* generator. Fast and allocation-free, so it is safe on the audio thread.
struct Random {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Float {
        Float(next() >> 40) * 0x1p-24
    }

    /// Uniform in [-1, 1).
    mutating func bipolar() -> Float {
        unit() * 2 - 1
    }

    mutating func range(_ low: Float, _ high: Float) -> Float {
        low + (high - low) * unit()
    }

    /// Log-uniform in [low, high), which spreads values evenly by octave.
    mutating func logRange(_ low: Float, _ high: Float) -> Float {
        low * pow(high / low, unit())
    }

    /// Standard normal (Box-Muller).
    mutating func gaussian() -> Float {
        let radius = (-2 * log(1 - unit())).squareRoot()
        return radius * cos(2 * .pi * unit())
    }
}

/// RBJ cookbook biquad coefficients, normalized by a0.
struct BiquadCoefficients {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0

    static func lowpass(_ frequency: Float, q: Float, sampleRate: Float) -> Self {
        let (cosw, alpha) = terms(frequency, q, sampleRate)
        let a0 = 1 + alpha
        let b1 = (1 - cosw) / a0
        return Self(b0: b1 / 2, b1: b1, b2: b1 / 2, a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
    }

    static func highpass(_ frequency: Float, q: Float, sampleRate: Float) -> Self {
        let (cosw, alpha) = terms(frequency, q, sampleRate)
        let a0 = 1 + alpha
        let b1 = -(1 + cosw) / a0
        return Self(b0: -b1 / 2, b1: b1, b2: -b1 / 2, a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
    }

    /// Band-pass with 0 dB gain at the center frequency.
    static func bandpass(_ frequency: Float, q: Float, sampleRate: Float) -> Self {
        let (cosw, alpha) = terms(frequency, q, sampleRate)
        let a0 = 1 + alpha
        return Self(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
    }

    private static func terms(_ frequency: Float, _ q: Float, _ sampleRate: Float) -> (Float, Float) {
        let w = 2 * Float.pi * min(frequency, sampleRate * 0.45) / sampleRate
        return (cos(w), sin(w) / (2 * q))
    }
}

/// Transposed direct form II state. Kept separate from the coefficients so
/// left and right channels can share one set of coefficients.
struct BiquadState {
    private var z1: Float = 0
    private var z2: Float = 0

    @inline(__always)
    mutating func process(_ x: Float, _ c: BiquadCoefficients) -> Float {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

/// Paul Kellet's pink noise filter, applied to white noise input.
struct PinkNoise {
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0
    private var b4: Float = 0, b5: Float = 0, b6: Float = 0

    @inline(__always)
    mutating func process(_ white: Float) -> Float {
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return pink * 0.11
    }
}

/// A smooth random signal, roughly in [-1, 1], that heads for a new random
/// target every so often. Used for swells, gusts, and clusters of drops.
struct Drift {
    private var target: Float = 0
    private var mid: Float = 0
    private var value: Float = 0
    private var ticksLeft = 0

    mutating func tick(_ rng: inout Random, minTicks: Int, maxTicks: Int, coefficient: Float) -> Float {
        if ticksLeft <= 0 {
            target = rng.bipolar()
            ticksLeft = minTicks + Int(rng.unit() * Float(max(maxTicks - minTicks, 0)))
        }
        ticksLeft -= 1
        mid += (target - mid) * coefficient
        value += (mid - value) * coefficient
        return value
    }
}

/// Peak limiter. Reacts within about a millisecond and recovers over a
/// quarter second, so a close thunder clap does not distort.
struct Limiter {
    private let threshold: Float
    private let release: Float
    private let attackSmoothing: Float
    private let releaseSmoothing: Float
    private var envelope: Float = 0
    private var gain: Float = 1

    init(threshold: Float, sampleRate: Float) {
        self.threshold = threshold
        release = exp(-1 / (0.25 * sampleRate))
        attackSmoothing = smoothing(0.001, rate: sampleRate)
        releaseSmoothing = smoothing(0.05, rate: sampleRate)
    }

    @inline(__always)
    mutating func gain(forPeak peak: Float) -> Float {
        envelope = max(peak, envelope * release)
        let target = envelope > threshold ? threshold / envelope : 1
        gain += (target - gain) * (target < gain ? attackSmoothing : releaseSmoothing)
        return gain
    }
}

/// One-pole smoothing coefficient for a time constant in seconds at a given update rate.
@inline(__always)
func smoothing(_ seconds: Float, rate: Float) -> Float {
    1 - exp(-1 / (seconds * rate))
}

/// Coefficient for a one-pole low-pass `y += (x - y) * c` with the given cutoff.
@inline(__always)
func onePoleCoefficient(_ frequency: Float, sampleRate: Float) -> Float {
    1 - exp(-2 * .pi * min(frequency, sampleRate * 0.45) / sampleRate)
}

/// Linear below 0.9, then a tanh knee that never exceeds 1.
@inline(__always)
func softClip(_ x: Float) -> Float {
    let threshold: Float = 0.9
    let magnitude = abs(x)
    if magnitude <= threshold { return x }
    let y = threshold + (1 - threshold) * tanh((magnitude - threshold) / (1 - threshold))
    return x < 0 ? -y : y
}
