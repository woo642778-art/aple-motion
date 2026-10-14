# Timing Video Export Implementation Plan

**Goal:** Turn the existing speed-curve core into a real, frame-sampled video export operation without substituting a new editor for Aple Motion.

**Architecture:** Add ApleTimingMedia alongside the existing core and UI. Index actual source presentation timestamps; evaluate the same SpeedRamp integral at each rational output timestamp; select the nearest source frame and encode it with AVFoundation. Existing host adapters are not presumed implemented.

**Execution:** Implement in this repository, use GitHub Actions macOS for compilation and tests. The local container, private Python and visible Python tools returned ClientError in this conversation. Do not claim this is a source-code problem, do not fabricate source bytes, and do not redistribute the supplied application publicly.

## Constraints

- Preserve existing Aple Motion executable, extensions, effects, project data and editor.
- No source or binary from a different editing project.
- Retiming preview and export must use SpeedRamp.sourceTime(at:).
- Frame sampling only: do not advertise optical flow, pitch preservation or HDR support.
- Reject audio-containing input unless the caller explicitly requests audio discard.
- Reject HDR input rather than silently claiming a lossless HDR result.
- Preserve source rotation; limit decoding dimensions and use bounded pixel-buffer allocation.
- Respect task cancellation; remove partial outputs on failure; never overwrite an existing output.
- Only package an integrated IPA after the real input bytes and verified host connection are available. A framework, diagnostic app or unchanged repack is not that IPA.

## Tasks

1. Repair the observed Bash 3.2 build failure (extra[@]: unbound variable), rerun the existing 24 core tests, upstream solver comparison and iOS/simulator compilation.
2. Add media tests for output validation, rational timestamps, fast playback, reverse and freeze using generated real video fixtures. Run them before implementing the media exporter.
3. Implement indexed source PTS selection and cancellable AVFoundation MP4 export with explicit audio and source-bound policies. Re-run fixture tests.
4. Compile ApleTimingMedia for arm64 iPhoneOS and arm64/x86_64 simulators. Include build reports and the module in artifacts.
5. Report exact verified coverage and host-integration/IPA status. Preserve working changes even when app-byte access is blocked.

## Review focus

Nonmonotone source time must not be confused with output timestamp monotonicity. Variable frame rate must use actual sample PTS, not duration minus nominal frame time. End-of-clip must not add a duplicate output frame. Audio removal must be explicit. Cancellation and failed writes must not leave a misleading completed MP4.
