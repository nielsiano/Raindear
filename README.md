# Rain

A macOS menu bar app that plays rain. Made for listening on headphones while you work.

The sound is generated in real time, not played from recordings, so it never loops.

## Install

Needs macOS 13 or later and Xcode or the Swift toolchain (5.9+).

```sh
make install   # builds Rain.app, copies it to /Applications and opens it
make run       # builds build/Rain.app and opens it from there
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
| Wind | Gusts. The rain also surges with them. |
| Thunder | How often thunder rolls in. 0 is never. The first roll comes a few seconds after you turn it up. |

Settings are saved when you change them. Launch at login works best with the app installed in /Applications.

## How the sound is made

`Sources/RainSynth` mixes five layers:

- **Rain**: pink noise plus a dense patter of thousands of tiny, quiet drops per second. The patter is what makes it sound like rain instead of static. A slow random swell keeps the intensity moving.
- **Drops**: short noise bursts through a band-pass filter, each with a random pitch, loudness and position. A few of them add the rising "plip" of a drop landing in a puddle.
- **Rumble**: low-passed brown noise.
- **Wind**: pink noise through a band-pass filter whose center frequency drifts with the gusts.
- **Thunder**: brown noise with a slow attack, a long decay, a low-pass that closes over time, and random dips in level for the roll. Distant strikes are quieter, darker and slower.

The Tone setting is a low-pass filter on the rain and drops. For headphones, a small amount of low-passed signal from each ear is mixed into the other (crossfeed), so hard-panned sounds do not feel like they are inside one ear. Play and pause fade in and out.

## Changing the sound

- Layer levels: `Level` in `Sources/RainSynth/RainSynth.swift`
- Synthesis details: `RainCore.updateControl` and `RainCore.spawnDrop` in the same file
- Presets: `Sources/RainSynth/RainSettings.swift`

To hear or measure a change without the menu bar app, render to a file:

```sh
swift run -c release rain-render --preset storm --seconds 30 --out storm.wav
swift run -c release rain-render --rain 0 --drops 0 --rumble 0 --wind 0 --thunder 1   # one layer alone
```

It prints the peak and RMS level. `make test` checks that every preset is audible, stays below full scale and fades to silence.

## Layout

```
Sources/Rain          menu bar app (SwiftUI MenuBarExtra, AVAudioEngine)
Sources/RainSynth     synthesis, settings and presets
Sources/rain-render   offline renderer
Tests/RainSynthTests  level and behavior tests
Support/Info.plist    app bundle metadata
```
