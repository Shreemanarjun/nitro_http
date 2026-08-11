#!/usr/bin/env python3
"""Regenerates doc/bench-<platform>.svg — the headline comparison charts.

Grouped columns, one group per scenario, one bar per client, `nitro_http` in the
accent hue and every competitor in a recessive slate. Each group keeps its OWN
y-scale, which is not a stylistic choice: the scenarios span 0.5 ms to 300 ms,
and a shared axis would render four of the five as invisible stubs. Every bar is
labelled with its value, so the scale being per-group cannot mislead.

Each group also carries how many of the 9 counted runs `nitro_http` won. That is
the number that decides whether a gap is real — 9/9 is a result, 5/9 is a coin
flip — and it is invisible in bar length, so it is printed.

Data: median p50 of 10 release runs per platform, first discarded as warm-up,
collected by tool/bench-macos.sh / tool/bench-android.sh / tool/bench-ios.sh and
aggregated by tool/bench_aggregate.py. Update this file and the README together.

Every row here is a RELEASE build on the hardware named in `meta` — no
simulators, no emulators, no debug timings. That is not pedantry: Flutter ships
no AOT snapshot for the iOS simulator, so a simulator can only report debug
numbers, and debug penalises Dart code far more than native code, which flatters
this package specifically. An emulator has already produced a fake 1.75-2.1x
download regression on this project that real hardware refuted outright.
"""

PLATFORMS = {
    "android": {
        # raw runs: build/bench/android-20260811-070007
        "title": "Android — nitro_http vs the field",
        "meta": "OnePlus 11 · Snapdragon 8 Gen 2 · 16 GB · Android 16",
        "scenarios": [
            ("small GET", "1 KiB", "8/9", [("nitro_http", 0.50), ("dart:io", 0.80), ("package:http", 0.83), ("dio", 1.12), ("rhttp", 2.84)]),
            ("64 GETs at once", "concurrency", "9/9", [("nitro_http", 18.94), ("rhttp", 26.36), ("dart:io", 29.79), ("package:http", 33.36), ("dio", 47.81)]),
            ("32 MiB download", "streamed", "9/9", [("nitro_http", 208.52), ("package:http", 279.84), ("dart:io", 284.68), ("dio", 291.70), ("rhttp", 299.16)]),
            ("8 MiB upload", "streamed", "6/9", [("nitro_http", 227.15), ("package:http", 244.41), ("dart:io", 248.42), ("dio", 248.94), ("rhttp", 271.83)]),
            ("mixed workload", "closest to an app", "9/9", [("nitro_http", 2.87), ("package:http", 5.41), ("dio", 6.30), ("dart:io", 6.41), ("rhttp", 8.49)]),
        ],
        "foot1": "median p50 of 10 release runs, first discarded as warm-up · in-process loopback, no TLS · thermally gated below 42 °C",
        "foot2": "fastest in all five scenarios; three of them in every single run. Mixed traffic finishes 312 req/s against 178 for the next best.",
    },
    "ios": {
        # raw runs: build/bench/ios-20260811-081602
        "title": "iOS — nitro_http vs the field",
        "meta": "iPhone 12 · A14 Bionic · 4 GB · iOS 26.6",
        "scenarios": [
            ("small GET", "1 KiB", "dart:io 7/9", [("dart:io", 0.13), ("nitro_http", 0.14), ("package:http", 0.14), ("rhttp", 0.16), ("dio", 0.20)]),
            ("64 GETs at once", "concurrency", "9/9", [("nitro_http", 4.22), ("rhttp", 4.36), ("package:http", 5.10), ("dart:io", 5.18), ("dio", 6.76)]),
            ("32 MiB download", "streamed", "7/9", [("nitro_http", 135.09), ("rhttp", 135.33), ("dio", 154.53), ("package:http", 155.81), ("dart:io", 156.75)]),
            ("8 MiB upload", "streamed", "package:http 8/9", [("package:http", 113.74), ("dart:io", 114.58), ("dio", 114.72), ("nitro_http", 116.83), ("rhttp", 123.30)]),
            ("mixed workload", "closest to an app", "9/9", [("nitro_http", 1.17), ("rhttp", 1.51), ("dart:io", 1.62), ("package:http", 1.64), ("dio", 2.27)]),
        ],
        "foot1": "median p50 of 10 release runs, first discarded as warm-up · in-process loopback, no TLS · physical device, release build",
        "foot2": "wins concurrency and mixed traffic in every run; 433 req/s mixed against 342 for the next best. Loses the 8 MiB upload by 2.7%.",
    },
    "macos": {
        # raw runs: build/bench/macos-20260811-014716
        "title": "macOS — nitro_http vs the field",
        "meta": "Apple M1 Pro · 16 GB · macOS 26.4",
        "scenarios": [
            ("small GET", "1 KiB", "dart:io 9/9", [("dart:io", 0.13), ("package:http", 0.13), ("nitro_http", 0.14), ("rhttp", 0.17), ("dio", 0.18)]),
            ("64 GETs at once", "concurrency", "5/9 · tie", [("nitro_http", 3.65), ("rhttp", 3.73), ("dart:io", 4.39), ("package:http", 4.43), ("dio", 6.49)]),
            ("32 MiB download", "streamed", "rhttp 8/9", [("rhttp", 124.40), ("nitro_http", 125.47), ("dio", 137.02), ("dart:io", 138.03), ("package:http", 138.37)]),
            ("8 MiB upload", "streamed", "no winner", [("package:http", 104.09), ("dart:io", 104.58), ("dio", 104.84), ("nitro_http", 106.90), ("rhttp", 112.16)]),
            ("mixed workload", "closest to an app", "9/9", [("nitro_http", 0.81), ("rhttp", 1.02), ("package:http", 1.26), ("dart:io", 1.29), ("dio", 1.32)]),
        ],
        "foot1": "median p50 of 10 release runs, first discarded as warm-up · in-process loopback, no TLS · machine idle-gated",
        "foot2": "wins the mixed workload in 9 of 9 runs; loses a single small GET by 0.01 ms, which is the FFI hop and any real network erases.",
    },
}

FOCUS = "nitro_http"

THEME = {
    "dark": dict(bg="#0e1116", panel="#151a21", ink="#ffffff", ink2="#8b949e",
                 ink3="#6e7681", accent="#3ddc97", accent2="#2bb583",
                 bar="#3d4756", grid="#232a33"),
    "light": dict(bg="#ffffff", panel="#f6f8fa", ink="#0b0b0b", ink2="#57606a",
                  ink3="#8c959f", accent="#0f9d76", accent2="#0b7d5e",
                  bar="#c3cbd5", grid="#e6eaef"),
}

W = 1180
PAD = 34
GROUP_H = 172          # one scenario row
BAR_W, BAR_GAP = 108, 46
HEAD_H, FOOT_H = 104, 62
MONO = "ui-monospace,SFMono-Regular,Menlo,monospace"
SANS = "-apple-system,Segoe UI,Helvetica,Arial,sans-serif"


def fmt(v):
    return f"{v:g}" if v < 10 else f"{v:.0f}"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


def chart(key, mode):
    p = PLATFORMS[key]
    t = THEME[mode]
    rows = len(p["scenarios"])
    h = HEAD_H + rows * GROUP_H + FOOT_H
    o = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}" '
        f'viewBox="0 0 {W} {h}" font-family="{SANS}">',
        f'<rect width="{W}" height="{h}" fill="{t["bg"]}" rx="14"/>',
        # Eyebrow + title, and the device on the right where it is findable but
        # never competes with the headline.
        f'<text x="{PAD}" y="46" font-family="{MONO}" font-size="13" letter-spacing="3" '
        f'fill="{t["accent"]}">NITRO_HTTP BENCHMARK</text>',
        f'<text x="{PAD}" y="80" font-size="27" font-weight="700" fill="{t["ink"]}">{esc(p["title"])}</text>',
        f'<text x="{W - PAD}" y="46" font-family="{MONO}" font-size="12.5" text-anchor="end" '
        f'fill="{t["ink2"]}">{esc(p["meta"])}</text>',
        f'<rect x="{W - PAD - 152}" y="66" width="11" height="11" rx="2.5" fill="{t["accent"]}"/>',
        f'<text x="{W - PAD - 136}" y="76" font-size="12.5" fill="{t["ink2"]}">nitro_http</text>',
        f'<rect x="{W - PAD - 66}" y="66" width="11" height="11" rx="2.5" fill="{t["bar"]}"/>',
        f'<text x="{W - PAD - 50}" y="76" font-size="12.5" fill="{t["ink2"]}">others</text>',
    ]

    for gi, (scenario, sub, won, values) in enumerate(p["scenarios"]):
        gy = HEAD_H + gi * GROUP_H
        base = gy + GROUP_H - 46          # baseline the columns sit on
        top = gy + 44                     # tallest bar reaches here
        o.append(f'<rect x="{PAD}" y="{gy + 6}" width="{W - 2 * PAD}" height="{GROUP_H - 18}" '
                 f'fill="{t["panel"]}" rx="10"/>')
        o.append(f'<text x="{PAD + 20}" y="{gy + 32}" font-size="15" font-weight="600" '
                 f'fill="{t["ink"]}">{esc(scenario)}</text>')
        o.append(f'<text x="{PAD + 24 + 9 * len(scenario)}" y="{gy + 32}" font-family="{MONO}" '
                 f'font-size="11.5" fill="{t["ink3"]}">{esc(sub)}</text>')
        # The reproducibility note, right-aligned in the group header.
        won_txt = f"nitro_http wins {won}" if won[0].isdigit() else won
        o.append(f'<text x="{W - PAD - 20}" y="{gy + 32}" font-family="{MONO}" font-size="11.5" '
                 f'text-anchor="end" fill="{t["ink3"]}">{esc(won_txt)}</text>')

        vmax = max(v for _, v in values)
        span = base - top
        # Baseline only; a full grid would fight five separate scales.
        o.append(f'<line x1="{PAD + 20}" y1="{base + 0.5}" x2="{W - PAD - 20}" y2="{base + 0.5}" '
                 f'stroke="{t["grid"]}" stroke-width="1"/>')

        n = len(values)
        total = n * BAR_W + (n - 1) * BAR_GAP
        x0 = (W - total) / 2
        best_i = min(range(len(values)), key=lambda i: values[i][1])
        for bi, (client, v) in enumerate(values):
            x = x0 + bi * (BAR_W + BAR_GAP)
            bh = max(4, span * v / vmax)
            y = base - bh
            focus = client == FOCUS
            fill = t["accent"] if focus else t["bar"]
            r = 5
            o.append(f'<path d="M{x} {base} v-{bh - r} a{r} {r} 0 0 1 {r} -{r} h{BAR_W - 2 * r} '
                     f'a{r} {r} 0 0 1 {r} {r} v{bh - r} z" fill="{fill}"/>')
            o.append(f'<text x="{x + BAR_W / 2}" y="{y - 9}" font-size="13" text-anchor="middle" '
                     f'font-weight="{700 if focus else 500}" '
                     f'fill="{t["accent"] if focus else t["ink2"]}">{fmt(v)}</text>')
            o.append(f'<text x="{x + BAR_W / 2}" y="{base + 19}" font-size="12" text-anchor="middle" '
                     f'font-weight="{700 if focus else 400}" '
                     f'fill="{t["ink"] if focus else t["ink2"]}">{esc(client)}</text>')
            if bi == best_i:
                o.append(f'<text x="{x + BAR_W / 2}" y="{base + 34}" font-family="{MONO}" '
                         f'font-size="10" text-anchor="middle" fill="{t["ink3"]}">fastest</text>')
        o.append(f'<text x="{PAD + 20}" y="{base + 19}" font-family="{MONO}" font-size="10.5" '
                 f'fill="{t["ink3"]}">ms · lower is better</text>')

    fy = HEAD_H + rows * GROUP_H + 16
    o.append(f'<text x="{PAD}" y="{fy}" font-family="{MONO}" font-size="11.5" '
             f'fill="{t["ink3"]}">{esc(p["foot1"])}</text>')
    o.append(f'<text x="{PAD}" y="{fy + 22}" font-size="12.5" fill="{t["ink2"]}">{esc(p["foot2"])}</text>')
    o.append("</svg>")
    return "\n".join(o)


def main():
    import pathlib
    doc = pathlib.Path(__file__).resolve().parent.parent / "doc"
    for key in PLATFORMS:
        for mode in THEME:
            path = doc / f"bench-{key}-{mode}.svg"
            path.write_text(chart(key, mode))
            print(path.name)


if __name__ == "__main__":
    main()
