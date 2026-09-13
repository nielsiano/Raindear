# Raindear

A macOS menu bar app that plays rain. Made for listening on headphones while you work.

The sound is generated in real time, not played from recordings, so it never loops.

## Install

Needs macOS 13 or later and Xcode or the Swift toolchain (5.9+).

```sh
make install   # builds Raindear.app, copies it to /Applications and opens it
make run       # builds build/Raindear.app and opens it from there
```

## Use

Click the raindrop in the menu bar. It is filled while rain is playing.

| Control | What it changes |
| --- | --- |
| Volume | Output level |
| Preset | Drizzle, Steady rain, Downpour, Rain on a roof, Behind a window, Thunderstorm. Moving a slider changes this to Custom. Presets keep your volume. |
| Rain | Density and loudness of the rain itself |
| Drops | Close, individual drops |
| Rumble | Low end, like heavy rain on a roof |
| Tone | Dark and muffled to bright and open |
| Wind | Gusts. The rain swells and surges with them. At 0 the rain stays steady. |
| Thunder | How often thunder rolls in. 0 is never. The first roll comes a few seconds after you turn it up. |

Settings are saved when you change them. Launch at login works best with the app installed in /Applications.

## How the sound is made

`Sources/RainSynth` mixes five layers:

- **Rain**: filtered white noise plus a patter of hundreds to thousands of very short, quiet, unpitched ticks per second. The patter is what makes it sound like rain instead of static. The rain has a fast flutter of its own. Slower swells and bursts come with wind, so with the Wind slider at 0 the rain stays steady.
- **Drops**: each close drop is a short broadband tick plus a softer, darker body, with a rounded attack and a random loudness and position. Drops alternate sides of center so light rain does not drift between the ears, and without wind they are spread evenly in time instead of bunching up.
- **Rumble**: low-passed brown noise.
- **Wind**: pink noise through a band-pass filter whose center frequency drifts with the gusts.
- **Thunder**: each strike is two to six claps over several seconds. Each clap opens a low-pass filter that then closes as the thunder rolls away. Distant strikes are quieter, darker and slower to build.

The Tone setting is a gentle low-pass on the rain and drops. The levels, spectrum and texture were tuned by comparing renders with recordings of real rain: spectrum by octave, how impulsive the sound is, and how much its loudness fluctuates at different speeds. The rain sits well below full scale so thunder can be clearly louder than it, and a limiter catches peaks at high volume.

For headphones, a small amount of low-passed signal from each ear is mixed into the other (crossfeed), so hard-panned sounds do not feel like they are inside one ear. Play and pause fade in and out.

## Changing the sound

- Layer levels: `Level` in `Sources/RainSynth/RainSynth.swift`
- How much the rain fluctuates: `Variation` in the same file
- Synthesis details: `RainCore.updateControl`, `spawnPatter`, `spawnDrop` and `Thunder` in the same file
- Presets: `Sources/RainSynth/RainSettings.swift`

To hear or measure a change without the menu bar app, render to a file:

```sh
swift run -c release rain-render --preset storm --seconds 30 --out storm.wav
swift run -c release rain-render --rain 0 --drops 0 --rumble 0 --wind 0 --thunder 1   # one layer alone
```

It prints the peak and RMS level. `make test` checks that every preset is audible, stays below full scale and fades to silence, and that thunder is clearly louder than the rain.

## Layout

```
Sources/Raindear      menu bar app (SwiftUI MenuBarExtra, AVAudioEngine)
Sources/RainSynth     synthesis, settings and presets
Sources/rain-render   offline renderer
Tests/RainSynthTests  level and behavior tests
Support/Info.plist    app bundle metadata
```

## License

MIT. See `LICENSE`.
