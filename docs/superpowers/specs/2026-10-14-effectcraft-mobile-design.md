# EffectCraft mobile integration design

The requested final outcome is an in-place upgrade of Aple Motion's editor with all EffectCraft functions adapted to iPhone and iPad, not a separate app or a web page placed over the editor. Existing editing, persistence, export, effects, captions and community functionality must remain available. The first deliverable addresses missing temporal controls; it must not be described as completion of the full request.

## Reference and architecture

Reference EffectCraft commit: `549e9d825132986d6167c1432cd3328efcbb0278`. Scalar temporal interpolation follows `crates/keyframe/src/lib.rs`: separate in/out interpolation, speed in units/second, influence as a fraction, auto-Bezier interior slopes, outgoing Hold, incoming Hold treated as linear, and non-rescaled crossing temporal handles. Spatial curves and roving keys are a separate milestone. Copying the scalar semantics does not establish whole-editor parity.

An additive Swift library contains a platform-independent numerical core and a UIKit timing inspector. The inspector requires a host adapter with a real layer snapshot, revision, preview, commit and cancel operations. No adapter for v4.34.38 is invented. Existing extension frameworks and project files must not be overwritten. A host transaction must write the layer mapping, invalidate preview/export caches, update undo history and persist before acknowledging success. Preview and export must use the same time map.

## Numerical requirements

Use 254016000000 ticks per second for stored time. Reject NaN, infinities, duplicate times, unsafe time spans and overflow. Support linear, Hold, independent Bezier sides, Easy Ease and interior auto-Bezier. Maintain both influences when their sum exceeds 100 percent, including the singular full-influence midpoint. Use the upstream 1ms central difference for displayed scalar velocity. Keep analytical values and speed-ramp integration separate.

For clip retiming, the keyframe value is speed in source-seconds per output-second. Integrate the cubic value polynomial times the time polynomial derivative analytically, including partial segments. Negative speed is reverse, zero speed is a freeze. Source bounds refer to valid presentation timestamps, not to an assumed constant-rate final frame. Expose explicit reject/clamp behavior instead of silently choosing a policy.

Frame schedules are rational, lazy and half-open: every output PTS is less than output duration. Never append an extra terminal frame. Validate serialization on decode. Unsupported schema versions must fail without overwriting the project.

## Mobile interaction

Use UIKit, iOS 15 or later, system fonts, minimum 44-point controls, a scrollable inspector, safe-area layout and adaptive graph sizing. Provide touch point editing plus explicit numeric controls, incoming/outgoing speed and influence, interpolation selection, Undo/Redo, Cancel and Apply. Apply must only report success after the supplied host adapter commits successfully. A graph display is not proof of integration.

## Release gates

Core tests, upstream scalar oracle comparison, arm64 iOS compilation, simulator compilation and a framework artifact are separate gates. Application integration, original-project round-trip, original export regression, physical-device memory/thermal/input testing and signing/install tests remain required for an IPA release. No reconstructed original IPA may be renamed as an upgraded build. The uploaded archives are analysis inputs, not source projects; their local processing currently fails with an execution-environment ClientError.
