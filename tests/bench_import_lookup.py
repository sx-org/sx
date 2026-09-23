#!/usr/bin/env python3
"""Compare Debug compiler codegen time on the stdlib-heavy HTTP server.

Usage: python3 tests/bench_import_lookup.py REFERENCE_SX CANDIDATE_SX
Both binaries must use the same toolchain and build options. Run on an idle host.
"""

import argparse
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    binaries = [args.reference.resolve(), args.candidate.resolve()]
    root = Path(__file__).resolve().parent.parent
    samples = [[], []]

    with tempfile.TemporaryDirectory(prefix="sx-import-lookup-") as scratch:
        def measure(index):
            result = subprocess.run(
                [str(binaries[index]), "build", "--time", "-o",
                 str(Path(scratch) / "http"), "examples/http/1633-http-server.sx"],
                cwd=root, capture_output=True, text=True,
            )
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            timing = re.search(r"^\s*codegen\s+([0-9.]+) ms$", result.stderr, re.M)
            if timing is None:
                raise RuntimeError("Missing codegen timing:\n" + result.stderr)
            return float(timing.group(1))

        for index in (0, 1):
            measure(index)
        for trial in range(5):
            for index in ((0, 1) if trial % 2 == 0 else (1, 0)):
                elapsed = measure(index)
                samples[index].append(elapsed)
                label = "reference" if index == 0 else "candidate"
                print(f"{label} trial {trial + 1}: {elapsed:.1f} ms", flush=True)

    reference, candidate = map(statistics.median, samples)
    ratio = candidate / reference
    passed = ratio <= 1.05
    print(f"median codegen: reference={reference:.1f} ms candidate={candidate:.1f} ms")
    print(f"candidate/reference={ratio:.3f}; limit=1.050; {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
