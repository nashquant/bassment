# Timbre

System-wide EQ for macOS. No driver: it uses Core Audio process taps (macOS 14.2+).

- eqMac-style 10-band graphic EQ with eqMac's presets (Bass Booster, Hip-Hop, Electronic, …) plus Blues and Funk.
- Bass / Mid / Treble sliders (±24 dB), mapped to the bands exactly like eqMac's Basic EQ.
- Preset and sliders are remembered per output device (soundbar, headphones, …).
- Optional AutoEQ headphone correction (Powerbeats Pro 2 built in; import any `ParametricEQ.txt`).
- Imports your own eqMac Advanced EQ presets.
- Advanced: editable parametric presets, simulated rooms (reverb), Audio Unit plugins, per-app volume.
- A peak limiter at the end of the chain. "Avoid clipping" (off by default, like eqMac) lowers the volume by the largest boost.

```
apps ─► taps (global + one per app with custom volume) ─► aggregate device ─► IOProc
IOProc ─► AVAudioEngine (manual render): EQ → plugins → room → limiter ─► default output
```

## Use

```bash
./scripts/bundle.sh                 # builds build/Timbre.app (ad hoc signature)
open build/Timbre.app
.build/release/Timbre --selftest
```

Debug: `open --env TIMBRE_DEBUG=1 --stderr /path/log build/Timbre.app` logs taps and signal peak.

Settings: `~/Library/Application Support/Timbre/settings.json`.

## Known limits

- Ad hoc signature: each new build asks for the audio-capture permission again.
- Do not run it together with eqMac: it refuses to start while eqMac is open.
- The drawn curve uses RBJ formulas; AVAudioUnitEQ may differ slightly.
- A plugin that does not accept stereo Float32 can crash the app when the chain is built.

See NOTICE for third-party data.
