#!/usr/bin/env python3
"""Numerical oracle for normalized scalar easing, not whole-editor parity."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REV = "549e9d825132986d6167c1432cd3328efcbb0278"
BLOB = "e0ee137bac8bd09398b2da13790ec47a028aaabc"
BASE = f"https://raw.githubusercontent.com/storytold/effectcraft/{REV}"
OUT = ROOT / "build" / "parity"
REPORTS = ROOT / "build" / "reports"


def fetch(path: str) -> bytes:
    with urllib.request.urlopen(f"{BASE}/{path}", timeout=30) as response:
        data = response.read(1_048_577)
    if len(data) > 1_048_576:
        raise RuntimeError("Upstream response exceeds the expected source size")
    return data


def extract(source: str, name: str) -> str:
    match = re.search(r"(?m)^(?:pub )?fn " + re.escape(name) + r"\(", source)
    if match is None:
        raise RuntimeError(f"Pinned function missing: {name}")
    opening = source.index("{", match.start())
    depth = 1
    for i in range(opening + 1, len(source)):
        depth += (source[i] == "{") - (source[i] == "}")
        if depth == 0:
            return source[match.start():i + 1]
    raise RuntimeError(f"Unbalanced source for {name}")


def run(command: list[str], *, input_text: str | None = None) -> str:
    result = subprocess.run(command, input=input_text, capture_output=True, text=True,
                            cwd=ROOT, timeout=180)
    if result.returncode:
        raise RuntimeError(f"Command failed: {command[0]}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    REPORTS.mkdir(parents=True, exist_ok=True)
    if shutil.which("rustc") is None:
        raise RuntimeError("rustc is required for the upstream numerical oracle")
    raw = fetch("crates/keyframe/src/lib.rs")
    actual_blob = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if actual_blob != BLOB:
        raise RuntimeError(f"Pinned upstream blob mismatch: {actual_blob}")
    source = raw.decode("utf-8")
    functions = "\n\n".join(extract(source, name) for name in ["bez", "bez_d", "solve_u", "ease_progress"])
    (OUT / "upstream.rs").write_text(functions + r'''
use std::io::Read;
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("read oracle input");
    for line in input.lines() {
        let p: Vec<f64> = line.split_whitespace().map(|x| x.parse().expect("finite number")).collect();
        assert_eq!(p.len(), 5);
        println!("{:.17e}", ease_progress(p[0], p[1], p[2], p[3], p[4]));
    }
}
''', encoding="utf-8")
    (OUT / "Oracle.swift").write_text(r'''
import Foundation
@main struct Oracle {
    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = String(data: data, encoding: .utf8) else { throw TimingError.invalidDocument }
        for line in input.split(separator: "\n") {
            let p = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
            guard p.count == 5 else { throw TimingError.invalidDocument }
            let value = try ScalarCurve.normalizedEase(outSpeed: p[0], outInfluence: p[1],
                inSpeed: p[2], inInfluence: p[3], progress: p[4])
            print(String(format: "%.17e", value))
        }
    }
}
''', encoding="utf-8")
    rust_exe, swift_exe = str(OUT / "rust-oracle"), str(OUT / "swift-oracle")
    run(["rustc", "--edition=2021", "-O", str(OUT / "upstream.rs"), "-o", rust_exe])
    run(["xcrun", "swiftc", "-O", str(ROOT / "Sources/ApleTimingCore/Time.swift"),
         str(ROOT / "Sources/ApleTimingCore/TemporalCurve.swift"), str(OUT / "Oracle.swift"), "-o", swift_exe])
    rng = random.Random(20261014)
    cases = []
    for speeds in [(0.0, 0.0), (-3.0, 2.0), (1.0, 1.0)]:
        for influences in [(0.0, 0.0), (1/3, 1/3), (0.9, 0.8), (1.0, 1.0)]:
            for x in [-0.1, 0.0, 0.1, 0.499999999999, 0.5, 0.500000000001, 0.9, 1.0, 1.1]:
                cases.append((speeds[0], influences[0], speeds[1], influences[1], x))
    cases.extend((rng.uniform(-5, 5), rng.random(), rng.uniform(-5, 5), rng.random(), rng.random())
                 for _ in range(2000))
    text = "\n".join(" ".join(format(v, ".17g") for v in case) for case in cases) + "\n"
    reference = [float(v) for v in run([rust_exe], input_text=text).splitlines()]
    port = [float(v) for v in run([swift_exe], input_text=text).splitlines()]
    if len(reference) != len(cases) or len(port) != len(cases):
        raise RuntimeError("An oracle omitted cases")
    differences = [abs(a-b) for a, b in zip(reference, port)]
    failures = [i for i, (a, b) in enumerate(zip(reference, port))
                if not abs(a-b) <= 1e-10 * max(1.0, abs(a), abs(b))]
    report = {"scope": "normalized scalar temporal easing only", "upstream_commit": REV,
              "upstream_blob": actual_blob, "cases": len(cases), "failures": len(failures),
              "max_absolute_error": max(differences), "relative_tolerance": 1e-10,
              "whole_editor_parity": False, "first_failure_indices": failures[:10]}
    (REPORTS / "upstream-parity.json").write_text(json.dumps(report, indent=2) + "\n")
    (REPORTS / "EffectCraft-MIT.txt").write_bytes(fetch("LICENSE-MIT"))
    print(json.dumps(report, indent=2))
    if failures:
        raise RuntimeError("Scalar easing differs from the pinned upstream oracle")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        REPORTS.mkdir(parents=True, exist_ok=True)
        (REPORTS / "parity-error.txt").write_text(str(error) + "\n")
        raise
