# Aple Motion: EffectCraft mobile integration

This repository is being initialized for an additive integration into the existing Aple Motion app. It is not a replacement editor and does not contain a completed IPA.

## Verified baseline (2026-10-14)

The target repository was empty when inspected. The supplied upload manifest identifies `Aple Motion v4.34.38 unsigned.ipa`, split into independent ZIP archives. The file inventory contains the compiled AlightMotion executable, `ExtensionsHost.framework/AEMotionExtensionsHost`, `Frameworks/ApleCaptions.framework`, and existing EditSpeed and EditEasing storyboard resources. The current v4.34.38 host source and project mutation API have not been verified.

Reference: EffectCraft `549e9d825132986d6167c1432cd3328efcbb0278` (version reported by its Cargo.toml: 0.9.2). Upstream: https://github.com/storytold/effectcraft. Its keyframe core defines separate incoming/outgoing interpolation, speed and influence; clip speed remapping is a distinct operation.

## First implementation milestone

`ApleTimingCore` provides scalar temporal Bezier keyframes and mathematically integrated clip-speed curves, explicit source-bound policies, exact rational frame scheduling, and validated project serialization. `ApleTimingUI` provides an adaptive native iPhone/iPad timing inspector. These modules must be connected to a verified host adapter before claiming an edit changes an existing Aple Motion layer.

## Non-negotiable integration requirements

Keep the existing project format, undo/redo, effect stacks, previews, captions, community features and export paths. Never replace the shipped extension frameworks with older versions. Keep the original editor reachable until replacement controls have functional and regression coverage. Use one authoritative project and time mapping for preview, persistence and export. Do not infer private Swift ABI or perform arbitrary pointer writes.

Full EffectCraft feature parity, spatial-path parity, engine integration, device performance and IPA installation are not established by this first module. A successful core test or framework build is not an application build.

## Build and validation

See `.github/workflows/timing.yml` and `scripts/build-framework.sh` when present. CI results, not this README, establish which checks actually passed. No signing credentials, uploaded IPA, embedded models or original bundled fonts are committed to this public repository.
