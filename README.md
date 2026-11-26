# Bassment

System-wide EQ for macOS. No driver: it uses Core Audio process taps (macOS 14.2+).

- 10-band graphic EQ with one-click presets (Bass Booster, Hip-Hop, Electronic, Funk, Jazz, …).
- Bass / Mid / Treble sliders (±24 dB) on top of any preset.
- Preset and sliders are global; each output device (soundbar, headphones, …) is detected and gets its own correction automatically.
- AutoEQ headphone correction, on automatically when a profile exists (Powerbeats Pro 2 built in; import any `ParametricEQ.txt`).
- Advanced: editable parametric presets, simulated rooms (reverb), Audio Unit plugins, per-app volume.
- A peak limiter at the end of the chain. "Avoid clipping" (off by default) lowers the volume by the largest boost.

```
apps ─► taps (global + one per app with custom volume) ─► aggregate device ─► IOProc
IOProc ─► AVAudioEngine (manual render): EQ → plugins → room → limiter ─► default output
```

## Use

```bash
./scripts/bundle.sh                 # builds build/Bassment.app (ad hoc signature)
./scripts/install.sh                # builds, installs to /Applications and restarts it
.build/release/Bassment --selftest
```

Debug: `open --env BASSMENT_DEBUG=1 --stderr /path/log build/Bassment.app` logs taps and signal peak.

Settings: `~/Library/Application Support/Bassment/settings.json`.

## Known limits

- Ad hoc signature: each new build asks for the audio-capture permission again.
- Do not run another system-wide EQ at the same time: Bassment refuses to start while a known one is open.
- The drawn curve uses RBJ formulas; AVAudioUnitEQ may differ slightly.
- A plugin that does not accept stereo Float32 can crash the app when the chain is built.

See NOTICE for third-party data.

## License

Apache License 2.0. See LICENSE and NOTICE.
