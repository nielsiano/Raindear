import RainSynth

let maxFrames = 4096

nonisolated(unsafe) var synth: RainSynth? = nil
nonisolated(unsafe) var settings = RainSettings()
nonisolated(unsafe) var leftBuffer: UnsafeMutablePointer<Float>? = nil
nonisolated(unsafe) var rightBuffer: UnsafeMutablePointer<Float>? = nil

@_expose(wasm, "rain_create") @_cdecl("rain_create")
public func rainCreate(_ sampleRate: Float, _ seedLow: UInt32, _ seedHigh: UInt32) {
    let seed = UInt64(seedHigh) << 32 | UInt64(seedLow)
    synth = RainSynth(settings: settings, playing: false, sampleRate: Double(sampleRate), seed: seed)
    if leftBuffer == nil {
        leftBuffer = .allocate(capacity: maxFrames)
        rightBuffer = .allocate(capacity: maxFrames)
    }
}

@_expose(wasm, "rain_set_settings") @_cdecl("rain_set_settings")
public func rainSetSettings(_ volume: Float, _ rain: Float, _ drops: Float, _ rumble: Float, _ tone: Float, _ wind: Float, _ thunder: Float) {
    settings = RainSettings(
        volume: Double(volume), rain: Double(rain), drops: Double(drops), rumble: Double(rumble),
        tone: Double(tone), wind: Double(wind), thunder: Double(thunder)
    )
    synth?.setSettings(settings)
}

@_expose(wasm, "rain_set_playing") @_cdecl("rain_set_playing")
public func rainSetPlaying(_ playing: Int32) {
    synth?.setPlaying(playing != 0)
}

/// Renders up to `rain_max_frames()` frames into the buffers at `rain_left()` and `rain_right()`.
@_expose(wasm, "rain_render") @_cdecl("rain_render")
public func rainRender(_ frames: Int32) {
    guard let synth, let leftBuffer, let rightBuffer else { return }
    synth.render(left: leftBuffer, right: rightBuffer, frameCount: min(Int(frames), maxFrames))
}

@_expose(wasm, "rain_left") @_cdecl("rain_left")
public func rainLeft() -> UnsafeMutablePointer<Float>? { leftBuffer }

@_expose(wasm, "rain_right") @_cdecl("rain_right")
public func rainRight() -> UnsafeMutablePointer<Float>? { rightBuffer }

@_expose(wasm, "rain_max_frames") @_cdecl("rain_max_frames")
public func rainMaxFrames() -> Int32 { Int32(maxFrames) }
