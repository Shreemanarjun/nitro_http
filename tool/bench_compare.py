#!/usr/bin/env python3
"""Merge a nitro_http benchmark run and a native-client run into one table.

The two sides are produced by different harnesses — the in-app Flutter matrix
(`NITRO_BENCH` rows, many runs) and a standalone native client (URLSession on
Apple, OkHttp on Android, one run printing `<scenario> p50 <n> <unit>`) — but
they hit the *same* `shelf` server with the *same* scenario set, so their p50s
are directly comparable. This turns the two into a side-by-side with a speedup
column, so "how fast is nitro_http vs the platform's native client" has one
answer per scenario instead of two files to eyeball.

  tool/bench_compare.py --platform macos --native-name URLSession \
      --nitro 'build/bench/macos-XXXX/run-*.txt' --native native.txt

speedup = native_p50 / nitro_p50:  > 1 means nitro_http is that much faster,
< 1 means the native client is 1/speedup faster. It is unit-free and works for
both the latency scenarios (small GET, burst) and the throughput ones (download,
upload), because MiB/s is just the inverse of p50 time over a fixed payload.
"""
from __future__ import annotations

import argparse
import glob
import re
import statistics
import sys

# The four scenarios both harnesses measure, in report order, with the payload
# a transfer moves (for the MiB/s column; latency scenarios leave it None). The
# sizes mirror release_runner.dart / the native harnesses: 32 MiB / 8 MiB.
SCENARIOS = [
    ("small GET", None),
    ("burst GET", None),
    ("download", 32 * 1024 * 1024),
    ("upload", 8 * 1024 * 1024),
]
UNIT_TO_MS = {"us": 1e-3, "ms": 1.0, "s": 1e3}


def nitro_p50s(files: list[str]) -> dict[str, float]:
    """Median across runs of each scenario's nitro_http p50, in ms.

    A row is `NITRO_BENCH | <scenario> | <client> | <count> | min | mean | p50 |
    ...`; p50 is the third number (field 6 once split on `|`). Only nitro_http
    rows count — the Dart competitors share the file but are not our subject.
    """
    per_scenario: dict[str, list[float]] = {}
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "NITRO_BENCH |" not in line or "| nitro_http |" not in line:
                    continue
                parts = line.split("|")
                if len(parts) < 7:
                    continue
                scenario = parts[1].strip()
                m = re.search(r"([\d.]+)", parts[6])
                if scenario and m:
                    per_scenario.setdefault(scenario, []).append(float(m.group(1)))
    return {s: statistics.median(v) for s, v in per_scenario.items() if v}


def native_p50s(path: str) -> dict[str, float]:
    """Each scenario's p50 in ms from a native run's `<scenario> p50 <n> <unit>`."""
    out: dict[str, float] = {}
    line_re = re.compile(
        r"^\s*(small GET|burst GET|download|upload)\s+p50\s+([\d.]+)\s*(us|ms|s)\b"
    )
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = line_re.match(line)
            if m:
                out[m.group(1)] = float(m.group(2)) * UNIT_TO_MS[m.group(3)]
    return out


def mibps(payload_bytes: int, ms: float) -> float:
    return (payload_bytes / 1_048_576.0) / (ms / 1000.0)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--nitro", required=True, help="glob for the NITRO_BENCH run files")
    ap.add_argument("--native", required=True, help="file with the native client's output")
    ap.add_argument("--native-name", default="native", help="label for the native column")
    ap.add_argument("--platform", default="", help="platform label for the header")
    ap.add_argument("--note", default="", help="one-line caveat printed under the table")
    args = ap.parse_args()

    nitro_files = sorted(glob.glob(args.nitro))
    if not nitro_files:
        print(f"no nitro run files matched {args.nitro!r}", file=sys.stderr)
        return 2
    nitro = nitro_p50s(nitro_files)
    native = native_p50s(args.native)
    if not native:
        print(f"no native scenarios parsed from {args.native!r}", file=sys.stderr)
        return 2

    nn = args.native_name
    head = f"### {args.platform or 'comparison'}: nitro_http vs {nn}"
    rows = [head, "",
            f"| scenario | nitro_http | {nn} | speedup | winner |",
            "|---|---|---|---|---|"]
    summary: list[str] = []
    for scenario, payload in SCENARIOS:
        a, b = nitro.get(scenario), native.get(scenario)
        if a is None or b is None:
            rows.append(f"| {scenario} | {'n/a' if a is None else f'{a:.2f} ms'}"
                        f" | {'n/a' if b is None else f'{b:.2f} ms'} | — | — |")
            continue
        speedup = b / a  # >1 => nitro faster
        if payload is None:
            av, bv = f"{a:.2f} ms", f"{b:.2f} ms"
        else:
            av = f"{a:.1f} ms ({mibps(payload, a):.0f} MiB/s)"
            bv = f"{b:.1f} ms ({mibps(payload, b):.0f} MiB/s)"
        if speedup >= 1.05:
            winner = f"**nitro {speedup:.1f}×**"
        elif speedup <= 0.95:
            winner = f"**{nn} {1/speedup:.1f}×**"
        else:
            winner = "parity"
        rows.append(f"| {scenario} | {av} | {bv} | {speedup:.2f}× | {winner} |")
        summary.append(f"{scenario}: {winner.replace('**', '')}")

    out = "\n".join(rows)
    if args.note:
        out += f"\n\n> {args.note}"
    print(out)
    print("\n" + " · ".join(summary), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
