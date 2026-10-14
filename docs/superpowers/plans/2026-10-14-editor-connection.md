# Aple editor connection implementation plan

> Execution: inline in the current session. No unrelated project is a source for this work.

**Goal:** connect the existing timing inspector to the supplied Aple Motion editor and produce a genuinely modified IPA, without substituting a stand-alone app.

**Spec:** `docs/superpowers/specs/2026-10-14-effectcraft-mobile-design.md`.

## Current evidence

The uploaded input is `Aple Motion v4.34.38 unsigned.ipa` represented by a manifest and two independently readable ZIPs. The repository has timing core and UI code, but `TimingHostAdapter` has no concrete implementation. This session's container and Python calls fail with `ClientError` before inspecting the uploaded bytes. The prior verification report is not a map of editor classes, method signatures or transaction semantics. GitHub source reads and branch creation work.

## Global constraints

Preserve the original compiled modules, resources, project storage and export behavior. Do not guess private selectors or Swift memory layouts. Do not upload original IPA contents, fonts, signing material or embedded models into this public repository. Never label an unchanged repack, a test fixture or a diagnostics-only build as the requested application. Tool-side safety and access controls remain in force.

## Tasks

- [ ] Add and run failing tests for a read-only input audit: complete part reconstruction, hashes, renamed upload parts, chunk ordering, path traversal, duplicate members, partial outputs and native metadata tool invocation.
- [ ] Implement `scripts/audit-aple-input.py`. It reads the supplied manifest, validates every piece and full-file SHA-256, temporarily reconstructs only Mach-O binaries, and optionally runs Apple's `otool` on those files. It writes reports only, never an IPA, and never executes the uploaded app.
- [ ] Run audit tests and the existing Swift acceptance suite in GitHub Actions on the work branch.
- [ ] Run the audit on the actual uploads when raw-byte execution is available. Identify actual class/method/type metadata, then verify selected-layer reads, reversible preview, original-editor undo and durable commit paths.
- [ ] Implement and verify the concrete adapter against those observed host paths. Check project save/reopen and preview/export time-map agreement.
- [ ] Compile native modules, integrate only verified bindings into the original bundle, and package an explicitly unsigned testing IPA. Report separately which installation/device gates remain untested.

## Review focus

Malformed archives must not write outside a temporary directory; source files must remain unchanged; a missing or failing Apple analysis tool must not look like completed native inspection; report archives must contain no original binaries; a successful audit is not evidence of a working host adapter.

## Execution ledger

Ruling: continue source-side work on an isolated branch while raw uploaded bytes are inaccessible. This can advance the evidence-gathering prerequisite but cannot establish native integration or produce the requested IPA by itself.
