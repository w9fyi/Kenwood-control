# RNNoise Integration Plan (macOS SwiftUI)

This is a concrete path to integrate RNNoise into the app as an in-process DSP stage. It assumes we will denoise the receive audio path first and add TX processing later if desired.

Sources
- Xiph RNNoise README (build, raw PCM, 48 kHz, model download, BSD-3 license)

## What RNNoise expects
- RNNoise operates on raw 16-bit mono PCM sampled at 48 kHz, and its reference demo uses raw PCM input/output. This implies we must resample and convert incoming audio before processing.
- The GitHub repo is a mirror; the canonical source lives on Xiph’s GitLab.

## Two integration shapes (recommendation: in-app DSP)
- In-app DSP (recommended): link RNNoise directly into the macOS app and run it in our audio pipeline. This yields the best accessibility control and least friction for users.
- Audio Unit plugin: not necessary right now and adds a lot of packaging and hosting complexity.

## Strategy (recommended: runtime-load from Homebrew for development)
- This repo now supports RNNoise via runtime loading (`dlopen`/`dlsym`) so the app still builds even if RNNoise isn’t installed.
- For development on macOS, install RNNoise with Homebrew and the app will pick it up automatically on next launch.
  - Apple Silicon default path: `/opt/homebrew/lib/librnnoise.dylib`
  - Intel Homebrew default path: `/usr/local/lib/librnnoise.dylib`

## Enable RNNoise locally
1. Install RNNoise:
   - `brew install rnnoise`
2. Relaunch the app.
3. The app will use RNNoise automatically (it probes common Homebrew paths at runtime).

## Notes
- RNNoise operates on 48 kHz mono frames (RNNoise’s reported frame size is typically 480 samples = 10 ms).
- Our audio pipelines already operate at 48 kHz mono float with 480-sample framing, so it’s a good fit.

## Audio pipeline placement
- For now, put RNNoise on the RX chain only.
- Later, optional TX chain can be added with a toggle for accessibility.
- Keep the DSP work on a dedicated serial queue to avoid UI stalls.

## Accessibility notes
- Expose a single on/off toggle with a clear label ("Noise Reduction").
- Expose a strength slider only if we add a secondary NR model or a wet/dry mix.
- Announce state changes via VoiceOver and support keyboard shortcuts.

## Risk checklist
- CPU usage and latency must stay low enough for real-time operation.
- Resampling quality must be good; we should test with CW and SSB.
- We will need to confirm RNNoise frame size from the header once vendored.
