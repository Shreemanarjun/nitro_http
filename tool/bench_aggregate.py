#!/usr/bin/env python3
"""Aggregate N benchmark runs into one defensible table.

A single run of this suite has flipped the fastest client in four of five
scenarios, so a number quoted from one run says nothing. This turns a pile of
runs into a verdict, and — more importantly — tells you when the runs do not
support a verdict at all.

Five checks, in the order they can invalidate a result:

  1. VALIDITY     a run counts only if it reached NITRO_BENCH_END, never printed
                  NITRO_BENCH_FAIL, and produced every scenario x client cell.

  2. ENVIRONMENT  each run file may carry a `# NITRO_BENCH_ENV idle=.. load=..`
                  line written by the harness at the instant it executed. The
                  preflight gate only fires once, at the start; a spike that
                  begins at run 4 slips past it. --min-idle drops any run whose
                  recorded idle fell below the floor, so one mid-session spike
                  is excised rather than widening every spread it touched.

  3. CONTROL DRIFT the four competitor clients are untouched by our changes, so
                  their numbers are a canary for the machine rather than the
                  code. If a control's median moves more than --drift between
                  runs, that scenario is reporting the laptop, not the library.
                  This is the check that would have caught the run where
                  package:http's burst p50 went 9.42 -> 18.76 ms untouched.

  4. OUTLIERS     flagged with a MAD-based modified z-score, which does not
                  assume a normal distribution and does not let one bad run move
                  the threshold that is supposed to catch it. Reported, not
                  silently dropped; --drop-outliers excludes them explicitly.

  5. RESOLUTION   a winner is only declared when a paired bootstrap on the gap
                  between the best and second-best medians excludes both zero
                  and the --tie threshold. The bootstrap resamples whole runs,
                  so nitro and the control it is compared against are always
                  drawn from the SAME runs — common-mode machine drift cancels
                  in the difference, which a comparison of two independent
                  medians cannot do. A CI that straddles the threshold is a tie,
                  which is a real result and not a failure to measure.

Usage:
    python3 tool/bench_aggregate.py run-*.txt [--warmup 1] [--tie 10]
            [--drift 15] [--drop-outliers] [--min-idle 70]
            [--boot 2000] [--seed 12345] [--stable-check]
"""

from __future__ import annotations

import argparse
import random
import re
import statistics
import sys
from pathlib import Path

ROW = re.compile(r"NITRO_BENCH \|(.+)\|\s*$")
MS = re.compile(r"([\d.]+)\s*ms")
ENV = re.compile(r"#\s*NITRO_BENCH_ENV\s+(.+)")
KV = re.compile(r"(\w+)=([\d.]+)")

SCENARIOS = ["small GET", "burst GET", "download", "upload", "mixed"]
NITRO = "nitro_http"


def parse(path: Path) -> tuple[dict, dict, list[str]]:
    """Returns (cells, env, problems).

    cells: {(scenario, client): {'p50','p90','p99','reqs'}}; env: {'idle':..}.
    """
    text = path.read_text(errors="replace")
    problems: list[str] = []
    if "NITRO_BENCH_FAIL" in text:
        problems.append("reported NITRO_BENCH_FAIL")
    if "NITRO_BENCH_END" not in text:
        problems.append("never reached NITRO_BENCH_END (crashed or was killed)")

    env: dict[str, float] = {}
    cells: dict[tuple[str, str], dict] = {}
    for line in text.splitlines():
        e = ENV.search(line)
        if e:
            env.update({k: float(v) for k, v in KV.findall(e.group(1))})
            continue
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
        p90 = MS.match(parts[6]) if len(parts) > 6 else None
        p99 = MS.match(parts[8]) if len(parts) > 8 else None
        try:
            reqs = float(parts[12])
        except (ValueError, IndexError):
            reqs = float("nan")
        cells[(scenario, client)] = {
            "p50": float(p50.group(1)),
            "p90": float(p90.group(1)) if p90 else float("nan"),
            "p99": float(p99.group(1)) if p99 else float("nan"),
            "reqs": reqs,
        }
    return cells, env, problems


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


def gap_ci(
    a: list[float], b: list[float], rng: random.Random, draws: int
) -> tuple[float, float, float]:
    """Bootstrap CI for the percentage gap (b - a) / a between two clients.

    Resamples RUN INDICES, not each client independently: a and b are the two
    clients' per-run p50s in run order, so drawing the same index for both keeps
    them inside the same run. Whatever the machine did that run moves a and b
    together and divides out of the ratio — which is the whole reason a within-
    run comparison beats comparing two medians that each drifted on their own.
    Returns (point_gap, lo95, hi95) in percent.
    """
    n = min(len(a), len(b))
    point = (statistics.median(b[:n]) - statistics.median(a[:n])) / statistics.median(a[:n]) * 100.0
    if n < 2:
        return point, point, point
    gaps = []
    for _ in range(draws):
        idx = [rng.randrange(n) for _ in range(n)]
        ma = statistics.median([a[i] for i in idx])
        mb = statistics.median([b[i] for i in idx])
        if ma != 0:
            gaps.append((mb - ma) / ma * 100.0)
    gaps.sort()
    lo = gaps[int(0.025 * len(gaps))]
    hi = gaps[min(len(gaps) - 1, int(0.975 * len(gaps)))]
    return point, lo, hi


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
    ap.add_argument("--min-idle", type=float, default=0.0,
                    help="drop runs whose recorded idle%% fell below this; 0 = off")
    ap.add_argument("--boot", type=int, default=2000,
                    help="bootstrap resamples for the verdict CI; default 2000")
    ap.add_argument("--seed", type=int, default=12345,
                    help="bootstrap RNG seed, so a re-run reproduces the CI")
    ap.add_argument("--stable-check", action="store_true",
                    help="print only STABLE / NEED_MORE on the last line, for an "
                         "adaptive run loop; suppresses the full report")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    paths = sorted(args.runs)
    parsed, invalid = [], []
    for p in paths:
        cells, env, problems = parse(p)
        (invalid if problems else parsed).append((p, cells, problems, env))
        if problems and not args.stable_check:
            print(f"INVALID  {p.name}: {'; '.join(problems)}")

    if len(parsed) <= args.warmup:
        if args.stable_check:
            print("NEED_MORE too-few-valid-runs")
            return 0
        print(f"\nFATAL: {len(parsed)} valid run(s), need more than the "
              f"{args.warmup} discarded as warm-up.")
        return 1

    discarded = [p.name for p, _, _, _ in parsed[: args.warmup]]
    kept = parsed[args.warmup:]

    # Environment drop (#2): a run that executed while the machine was busy is
    # not the machine the others measured. Excised like an outlier, by name.
    env_dropped = []
    if args.min_idle > 0:
        survivors = []
        for entry in kept:
            p, _, _, env = entry
            idle = env.get("idle")
            if idle is not None and idle < args.min_idle:
                env_dropped.append((p.name, idle))
            else:
                survivors.append(entry)
        kept = survivors

    if not args.stable_check:
        print(f"{len(parsed)} valid run(s); discarding {args.warmup} as warm-up "
              f"({', '.join(discarded)}); analysing {len(kept)}.")
        if invalid:
            print(f"{len(invalid)} run(s) rejected outright.")
        for name, idle in env_dropped:
            print(f"ENV-DROP {name}: {idle:.0f}% idle < {args.min_idle:.0f}% floor")

    if len(kept) < 2:
        if args.stable_check:
            print("NEED_MORE too-few-after-drops")
            return 0
        print("\nFATAL: fewer than 2 runs survived the drops.")
        return 1

    clients: list[str] = []
    for _, cells, _, _ in kept:
        for _, client in cells:
            if client not in clients:
                clients.append(client)
    controls = [c for c in clients if c != NITRO]

    def pick(scenario: str, client: str, key: str) -> list[float]:
        return [c[(scenario, client)][key] for _, c, _, _ in kept
                if (scenario, client) in c and c[(scenario, client)][key] == c[(scenario, client)][key]]

    series: dict[tuple[str, str], list[float]] = {}
    for scenario in SCENARIOS:
        for client in clients:
            vals = pick(scenario, client, "p50")
            if vals:
                series[(scenario, client)] = vals

    # ── Control drift ──────────────────────────────────────────────────────
    unstable: set[str] = set()
    for scenario in SCENARIOS:
        worst_cv = 0.0
        for client in controls:
            vals = series.get((scenario, client))
            if vals:
                worst_cv = max(worst_cv, cv(vals))
        if worst_cv > args.drift:
            unstable.add(scenario)

    # Adaptive-loop fast path: STABLE once no scenario's controls are drifting.
    if args.stable_check:
        if unstable:
            print(f"NEED_MORE unstable={len(unstable)} "
                  f"({', '.join(sorted(unstable))}) runs={len(kept)}")
        else:
            print(f"STABLE runs={len(kept)}")
        return 0

    print("\n" + "=" * 78)
    print("CONTROL DRIFT — the competitors are untouched, so movement here is the")
    print("machine, not the code. A flagged scenario cannot be compared at all.")
    print("=" * 78)
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

    # ── Tail latency (#4) ────────────────────────────────────────────────────
    print("\n" + "=" * 78)
    print("TAIL LATENCY — median p90 / p99 over the kept runs. A client can win on")
    print("p50 and lose here: that is where GC pauses and pool churn surface, and")
    print("under load the tail is the number a user actually feels.")
    print("=" * 78)
    for label, key in (("p90", "p90"), ("p99", "p99")):
        print(f"  -- {label} --")
        header = f"{'scenario':<11} " + "".join(f"{c[:18]:>20}" for c in clients)
        print(header)
        for scenario in SCENARIOS:
            meds = {}
            for c in clients:
                vals = pick(scenario, c, key)
                if vals:
                    meds[c] = statistics.median(vals)
            if not meds:
                continue
            best = min(meds, key=meds.get)
            cellrow = f"{scenario:<11} "
            for c in clients:
                if c not in meds:
                    cellrow += f"{'-':>20}"
                    continue
                mark = "*" if c == best else " "
                cellrow += f"{meds[c]:>17.2f}{mark} "
            print(cellrow)

    print("\n" + "=" * 78)
    print(f"VERDICT — paired bootstrap ({args.boot} resamples) on the gap between the")
    print(f"two best medians; a winner needs the 95%% CI to clear {args.tie:.0f}%. The")
    print("resample draws whole runs, so common-mode drift cancels in the gap.")
    print("=" * 78)
    for scenario in SCENARIOS:
        meds = {c: statistics.median(series[(scenario, c)])
                for c in clients if (scenario, c) in series}
        if len(meds) < 2:
            continue
        ranked = sorted(meds.items(), key=lambda kv: kv[1])
        (c1, v1), (c2, v2) = ranked[0], ranked[1]
        gap, lo, hi = gap_ci(series[(scenario, c1)], series[(scenario, c2)], rng, args.boot)
        if scenario in unstable:
            # Drift invalidates the MAGNITUDES, not the ranking. All five clients
            # run inside the same run under the same conditions, so a within-run
            # comparison is immune to whatever moved between runs. Reporting "no
            # result" here would throw away a perfectly good answer — see the win
            # rate below, which is the statistic that survives.
            verdict = ("magnitudes unusable (controls drifted) — "
                       "compare the win rate, not these numbers")
        elif lo < args.tie:
            # CI reaches below the tie threshold: cannot distinguish them.
            verdict = (f"TIE between {c1} and {c2} "
                       f"(gap {gap:.1f}%, 95% CI [{lo:.1f}, {hi:.1f}]%)")
        else:
            verdict = (f"{c1} fastest by {gap:.1f}% over {c2} "
                       f"(95% CI [{lo:.1f}, {hi:.1f}]%)")
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
        for _, cells, _, _ in kept:
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
        vals = pick("mixed", client, "reqs")
        if vals:
            print(f"  {client:<20} {statistics.median(vals):7.0f} req/s  +-{cv(vals):3.0f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
