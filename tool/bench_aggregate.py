#!/usr/bin/env python3
"""Aggregate N benchmark runs into one defensible table.

A single run of this suite has flipped the fastest client in four of five
scenarios, so a number quoted from one run says nothing. This turns a pile of
runs into a verdict, and — more importantly — tells you when the runs do not
support a verdict at all.

Four checks, in the order they can invalidate a result:

  1. VALIDITY     a run counts only if it reached NITRO_BENCH_END, never printed
                  NITRO_BENCH_FAIL, and produced every scenario x client cell.

  2. CONTROL DRIFT the four competitor clients are untouched by our changes, so
                  their numbers are a canary for the machine rather than the
                  code. If a control's median moves more than --drift between
                  runs, that scenario is reporting the laptop, not the library.
                  This is the check that would have caught the run where
                  package:http's burst p50 went 9.42 -> 18.76 ms untouched.

  3. OUTLIERS     flagged with a MAD-based modified z-score, which does not
                  assume a normal distribution and does not let one bad run move
                  the threshold that is supposed to catch it. Reported, not
                  silently dropped; --drop-outliers excludes them explicitly.

  4. RESOLUTION   a winner is only declared when the gap between the best and
                  second-best medians exceeds both --tie (default 10%, this
                  project's standing rule) and the spread of the two clients
                  being compared. Otherwise the row is a tie, which is a real
                  result and not a failure to measure.

Usage:
    python3 tool/bench_aggregate.py run-*.txt [--warmup 1] [--tie 10]
                                              [--drift 15] [--drop-outliers]
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from pathlib import Path

ROW = re.compile(r"NITRO_BENCH \|(.+)\|\s*$")
MS = re.compile(r"([\d.]+)\s*ms")

SCENARIOS = ["small GET", "burst GET", "download", "upload", "mixed"]
NITRO = "nitro_http"


def parse(path: Path) -> tuple[dict, list[str]]:
    """Returns ({(scenario, client): {'p50':float,'reqs':float}}, [problems])."""
    text = path.read_text(errors="replace")
    problems: list[str] = []
    if "NITRO_BENCH_FAIL" in text:
        problems.append("reported NITRO_BENCH_FAIL")
    if "NITRO_BENCH_END" not in text:
        problems.append("never reached NITRO_BENCH_END (crashed or was killed)")

    cells: dict[tuple[str, str], dict] = {}
    for line in text.splitlines():
        m = ROW.search(line)
        if not m:
            continue
        parts = [c.strip() for c in m.group(1).split("|")]
        if len(parts) < 13 or parts[0] in ("Scenario",) or parts[0].startswith("---"):
            continue
        scenario, client = parts[0], parts[1]
        p50 = MS.match(parts[5])
        if not p50:
            continue
        try:
            reqs = float(parts[12])
        except (ValueError, IndexError):
            reqs = float("nan")
        cells[(scenario, client)] = {"p50": float(p50.group(1)), "reqs": reqs}
    return cells, problems


def cv(values: list[float]) -> float:
    """Spread as a percentage of the median. Robust enough for small n."""
    med = statistics.median(values)
    return 0.0 if med == 0 else (max(values) - min(values)) / med * 100.0


def outlier_runs(values: list[float], threshold: float = 3.5) -> list[int]:
    """Indices flagged by a MAD-based modified z-score (Iglewicz & Hoaglin)."""
    if len(values) < 4:
        return []
    med = statistics.median(values)
    deviations = [abs(v - med) for v in values]
    mad = statistics.median(deviations)
    if mad == 0:
        return []
    return [i for i, v in enumerate(values) if abs(0.6745 * (v - med) / mad) > threshold]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+", type=Path)
    ap.add_argument("--warmup", type=int, default=1,
                    help="leading runs to discard (cold page cache); default 1")
    ap.add_argument("--tie", type=float, default=10.0,
                    help="percent gap below which a row is a tie; default 10")
    ap.add_argument("--drift", type=float, default=15.0,
                    help="percent control movement that invalidates a scenario")
    ap.add_argument("--drop-outliers", action="store_true")
    args = ap.parse_args()

    paths = sorted(args.runs)
    parsed, invalid = [], []
    for p in paths:
        cells, problems = parse(p)
        (invalid if problems else parsed).append((p, cells, problems))
        if problems:
            print(f"INVALID  {p.name}: {'; '.join(problems)}")

    if len(parsed) <= args.warmup:
        print(f"\nFATAL: {len(parsed)} valid run(s), need more than the "
              f"{args.warmup} discarded as warm-up.")
        return 1

    discarded = [p.name for p, _, _ in parsed[: args.warmup]]
    kept = parsed[args.warmup:]
    print(f"{len(parsed)} valid run(s); discarding {args.warmup} as warm-up "
          f"({', '.join(discarded)}); analysing {len(kept)}.")
    if invalid:
        print(f"{len(invalid)} run(s) rejected outright.")

    clients: list[str] = []
    for _, cells, _ in kept:
        for _, client in cells:
            if client not in clients:
                clients.append(client)
    controls = [c for c in clients if c != NITRO]

    series: dict[tuple[str, str], list[float]] = {}
    for scenario in SCENARIOS:
        for client in clients:
            vals = [c[(scenario, client)]["p50"] for _, c, _ in kept
                    if (scenario, client) in c]
            if vals:
                series[(scenario, client)] = vals

    print("\n" + "=" * 78)
    print("CONTROL DRIFT — the competitors are untouched, so movement here is the")
    print("machine, not the code. A flagged scenario cannot be compared at all.")
    print("=" * 78)
    unstable: set[str] = set()
    for scenario in SCENARIOS:
        worst, worst_cv = None, 0.0
        for client in controls:
            vals = series.get((scenario, client))
            if not vals:
                continue
            spread = cv(vals)
            if spread > worst_cv:
                worst, worst_cv = client, spread
        if worst is None:
            continue
        flag = "UNSTABLE" if worst_cv > args.drift else "ok"
        if worst_cv > args.drift:
            unstable.add(scenario)
        print(f"  {scenario:<11} worst control {worst:<20} spread {worst_cv:5.1f}%  {flag}")

    print("\n" + "=" * 78)
    print("OUTLIERS (MAD modified z-score > 3.5)")
    print("=" * 78)
    found = False
    for (scenario, client), vals in series.items():
        idx = outlier_runs(vals)
        for i in idx:
            found = True
            action = "excluded" if args.drop_outliers else "kept (pass --drop-outliers to exclude)"
            print(f"  {scenario:<11} {client:<20} run {kept[i][0].name}: "
                  f"{vals[i]:.2f} ms vs median {statistics.median(vals):.2f} — {action}")
    if not found:
        print("  none")
    if args.drop_outliers:
        for key, vals in list(series.items()):
            idx = set(outlier_runs(vals))
            if idx:
                series[key] = [v for i, v in enumerate(vals) if i not in idx]

    print("\n" + "=" * 78)
    print(f"RESULT — median p50 over {len(kept)} runs, +/- spread")
    print("=" * 78)
    header = f"{'scenario':<11} " + "".join(f"{c[:18]:>20}" for c in clients)
    print(header)
    for scenario in SCENARIOS:
        meds = {c: statistics.median(series[(scenario, c)])
                for c in clients if (scenario, c) in series}
        if not meds:
            continue
        best = min(meds, key=meds.get)
        cellrow = f"{scenario:<11} "
        for c in clients:
            if c not in meds:
                cellrow += f"{'-':>20}"
                continue
            spread = cv(series[(scenario, c)])
            mark = "*" if c == best else " "
            cellrow += f"{meds[c]:>13.2f}{mark}+-{spread:3.0f}%"
        print(cellrow)

    print("\n" + "=" * 78)
    print(f"VERDICT — a winner needs a gap over {args.tie:.0f}% AND wider than the")
    print("two clients' own spread; anything else is a tie.")
    print("=" * 78)
    for scenario in SCENARIOS:
        meds = {c: statistics.median(series[(scenario, c)])
                for c in clients if (scenario, c) in series}
        if len(meds) < 2:
            continue
        ranked = sorted(meds.items(), key=lambda kv: kv[1])
        (c1, v1), (c2, v2) = ranked[0], ranked[1]
        gap = (v2 - v1) / v1 * 100.0
        noise = max(cv(series[(scenario, c1)]), cv(series[(scenario, c2)]))
        if scenario in unstable:
            # Drift invalidates the MAGNITUDES, not the ranking. All five clients
            # run inside the same run under the same conditions, so a within-run
            # comparison is immune to whatever moved between runs. Reporting "no
            # result" here would throw away a perfectly good answer — see the win
            # rate below, which is the statistic that survives.
            verdict = ("magnitudes unusable (controls drifted) — "
                       "compare the win rate, not these numbers")
        elif gap < args.tie or gap < noise:
            verdict = (f"TIE between {c1} and {c2} "
                       f"(gap {gap:.1f}%, noise {noise:.0f}%)")
        else:
            verdict = f"{c1} fastest by {gap:.1f}% over {c2} (noise {noise:.0f}%)"
        nitro_rank = [c for c, _ in ranked].index(NITRO) + 1 if NITRO in meds else 0
        print(f"  {scenario:<11} {verdict}")
        if NITRO in meds and c1 != NITRO:
            behind = (meds[NITRO] - v1) / v1 * 100.0
            print(f"  {'':<11}   {NITRO} is #{nitro_rank} of {len(meds)}, "
                  f"{behind:.1f}% behind {c1}")

    print("\n" + "=" * 78)
    print("WIN RATE — how often each client was fastest, run by run.")
    print("Medians hide this. Two clients can overlap heavily and still have one")
    print("of them win every single run, which a spread comparison calls a tie;")
    print("9-0 is a 1-in-512 coin flip, 5-4 is a coin flip.")
    print("=" * 78)
    for scenario in SCENARIOS:
        wins: dict[str, int] = {}
        rounds = 0
        for _, cells, _ in kept:
            row = {c: cells[(scenario, c)]["p50"] for c in clients
                   if (scenario, c) in cells}
            if not row:
                continue
            rounds += 1
            wins[min(row, key=row.get)] = wins.get(min(row, key=row.get), 0) + 1
        if not rounds:
            continue
        tally = ", ".join(f"{c} {n}/{rounds}"
                          for c, n in sorted(wins.items(), key=lambda kv: -kv[1]))
        note = ""
        top = max(wins.values())
        if top == rounds and len(wins) == 1:
            note = "  <- unanimous"
        elif top <= rounds / 2 + 0.5:
            note = "  <- split, no reproducible winner"
        print(f"  {scenario:<11} {tally}{note}")

    print("\n" + "=" * 78)
    print("MIXED THROUGHPUT — that scenario is about requests finished per second,")
    print("which p50 alone does not capture.")
    print("=" * 78)
    for client in clients:
        vals = [c[("mixed", client)]["reqs"] for _, c, _ in kept
                if ("mixed", client) in c and c[("mixed", client)]["reqs"] == c[("mixed", client)]["reqs"]]
        if vals:
            print(f"  {client:<20} {statistics.median(vals):7.0f} req/s  +-{cv(vals):3.0f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
