#!/usr/bin/env python3
"""Regenerates doc/bench-*.svg from the measured benchmark medians.

Emphasis form: nitro_http carries the accent hue, every other client is a
de-emphasis gray — the chart's job is "where does this client stand", not
"tell five clients apart". Each panel has its own x-scale because the
scenarios span 0.15 ms to 300 ms; every bar is direct-labeled with client
and value, so identity is never color-alone.

Data = median of 3 release runs per platform (Android: the coldest of three
sets). Source: README "Measured performance". Update BOTH when re-measuring.
"""

DATA = {
    "macos": ("macOS — Apple M1 Pro", [
        ("small GET",  [("nitro_http", 0.17), ("dart:io", 0.15), ("package:http", 0.15), ("dio", 0.21), ("rhttp", 0.18)]),
        ("64 concurrent GETs", [("nitro_http", 3.60), ("dart:io", 5.15), ("package:http", 5.11), ("dio", 7.40), ("rhttp", 4.14)]),
        ("32 MiB download", [("nitro_http", 128.02), ("dart:io", 139.76), ("package:http", 136.86), ("dio", 138.14), ("rhttp", 127.77)]),
        ("8 MiB upload", [("nitro_http", 108.19), ("dart:io", 109.94), ("package:http", 108.55), ("dio", 106.78), ("rhttp", 116.10)]),
        ("mixed workload", [("nitro_http", 1.08), ("dart:io", 1.33), ("package:http", 1.54), ("dio", 1.44), ("rhttp", 1.46)]),
    ]),
    "ios": ("iOS — iPhone 12 (A14)", [
        ("small GET",  [("nitro_http", 0.15), ("dart:io", 0.14), ("package:http", 0.14), ("dio", 0.20), ("rhttp", 0.17)]),
        ("64 concurrent GETs", [("nitro_http", 4.28), ("dart:io", 5.20), ("package:http", 5.18), ("dio", 6.70), ("rhttp", 4.39)]),
        ("32 MiB download", [("nitro_http", 135.52), ("dart:io", 148.14), ("package:http", 146.55), ("dio", 145.90), ("rhttp", 135.36)]),
        ("8 MiB upload", [("nitro_http", 115.03), ("dart:io", 112.37), ("package:http", 111.78), ("dio", 112.66), ("rhttp", 119.42)]),
        ("mixed workload", [("nitro_http", 1.23), ("dart:io", 1.73), ("package:http", 1.57), ("dio", 2.40), ("rhttp", 1.39)]),
    ]),
    "android": ("Android — OnePlus CPH2447", [
        ("small GET",  [("nitro_http", 0.40), ("dart:io", 0.33), ("package:http", 0.33), ("dio", 0.64), ("rhttp", 0.89)]),
        ("64 concurrent GETs", [("nitro_http", 14.77), ("dart:io", 18.07), ("package:http", 26.76), ("dio", 37.08), ("rhttp", 21.60)]),
        ("32 MiB download", [("nitro_http", 214.53), ("dart:io", 286.42), ("package:http", 265.22), ("dio", 273.02), ("rhttp", 295.11)]),
        ("8 MiB upload", [("nitro_http", 202.26), ("dart:io", 173.47), ("package:http", 178.04), ("dio", 215.49), ("rhttp", 238.69)]),
        ("mixed workload", [("nitro_http", 2.18), ("dart:io", 5.14), ("package:http", 5.04), ("dio", 4.20), ("rhttp", 3.57)]),
    ]),
}

MODES = {
    # dataviz default palette: accent = categorical slot 1, per-mode step.
    "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e",
                  accent="#2a78d6", gray="#b8b7b2", panel="#f0efec"),
    "dark":  dict(surface="#1a1a19", ink="#ffffff", ink2="#c3c2b7",
                  accent="#3987e5", gray="#55554f", panel="#262624"),
}

FOCUS = "nitro_http"

PANEL_W, PANEL_H, COLS, PAD = 420, 148, 2, 14
# VALUE_W reserves room for the label to the right of a FULL-width bar
# ("999 ms" plus padding). The "· fastest" suffix never collides — the winner
# has the shortest bar by construction, so its label has the whole track.
BAR_H, BAR_GAP, LABEL_W, VALUE_W = 13, 7, 96, 118


def fmt(v):
    return f"{v:g} ms" if v < 10 else f"{v:.0f} ms"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


def platform_svg(key, mode):
    title, panels = DATA[key]
    m = MODES[mode]
    rows = (len(panels) + COLS - 1) // COLS
    w = COLS * PANEL_W + (COLS + 1) * PAD
    h = rows * PANEL_H + (rows + 1) * PAD + 46
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif">',
        f'<rect width="{w}" height="{h}" fill="{m["surface"]}" rx="8"/>',
        f'<text x="{PAD + 2}" y="26" font-size="15" font-weight="600" fill="{m["ink"]}">{esc(title)}</text>',
        f'<text x="{PAD + 2}" y="42" font-size="11" fill="{m["ink2"]}">p50, release, median of 3 runs — lower is better · '
        f'<tspan fill="{m["accent"]}" font-weight="600">▮ nitro_http</tspan> · ▮ other clients</text>',
    ]
    for i, (scenario, values) in enumerate(panels):
        px = PAD + (i % COLS) * (PANEL_W + PAD)
        py = 46 + PAD + (i // COLS) * (PANEL_H + PAD)
        out.append(f'<rect x="{px}" y="{py}" width="{PANEL_W}" height="{PANEL_H}" fill="{m["panel"]}" rx="6"/>')
        out.append(f'<text x="{px + 10}" y="{py + 18}" font-size="12" font-weight="600" fill="{m["ink"]}">{esc(scenario)}</text>')
        ranked = sorted(values, key=lambda kv: kv[1])
        vmax = max(v for _, v in values)
        track = PANEL_W - LABEL_W - VALUE_W - 30
        for j, (client, v) in enumerate(ranked):
            y = py + 30 + j * (BAR_H + BAR_GAP)
            focus = client == FOCUS
            fill = m["accent"] if focus else m["gray"]
            bw = max(3, track * v / vmax)
            out.append(
                f'<text x="{px + 10 + LABEL_W - 6}" y="{y + BAR_H - 3}" font-size="10.5" text-anchor="end" '
                f'fill="{m["ink"] if focus else m["ink2"]}" font-weight="{600 if focus else 400}">{esc(client)}</text>')
            # Rounded data-end only (right); baseline end stays square.
            r = 4
            out.append(
                f'<path d="M{px + 10 + LABEL_W} {y} h{bw - r} a{r} {r} 0 0 1 {r} {r} v{BAR_H - 2 * r} '
                f'a{r} {r} 0 0 1 -{r} {r} h-{bw - r} z" fill="{fill}"/>')
            label = fmt(v) + (" · fastest" if j == 0 else "")
            out.append(
                f'<text x="{px + 14 + LABEL_W + bw}" y="{y + BAR_H - 3}" font-size="10.5" '
                f'fill="{m["ink"] if j == 0 else m["ink2"]}" font-weight="{600 if j == 0 else 400}">{label}</text>')
    out.append("</svg>")
    return "\n".join(out)




# ── Android dispatch-mode grid ───────────────────────────────────────────────
# One run per dispatch mode on the OnePlus 11 (SD 8 Gen 2, 16 GB, Android 16),
# release APK, in-process loopback server. p50 ms. Heavier workload than the
# platform charts: 989 small GETs, burst 126 x 10 primed, 256 MiB download,
# 128 MiB upload, 407 mixed requests.
ANDROID_MODES = {
    "Serial": [
        ("small GET", [("nitro_http", 0.74), ("dart:io", 0.91), ("package:http", 0.94), ("dio", 1.34), ("rhttp", 2.20)]),
        ("burst 126 GETs", [("nitro_http", 41.22), ("dart:io", 47.23), ("package:http", 64.73), ("dio", 95.93), ("rhttp", 39.44)]),
        ("256 MiB download", [("nitro_http", 1822.03), ("dart:io", 2482.23), ("package:http", 2497.30), ("dio", 2520.45), ("rhttp", 2025.81)]),
        ("128 MiB upload", [("nitro_http", 4110.13), ("dart:io", 4236.60), ("package:http", 4322.34), ("dio", 4226.25), ("rhttp", 4644.86)]),
        ("mixed workload", [("nitro_http", 4.10), ("dart:io", 4.83), ("package:http", 4.45), ("dio", 5.01), ("rhttp", 8.68)]),
    ],
    "Concurrent (100 in flight)": [
        ("small GET", [("nitro_http", 34.54), ("dart:io", 61.67), ("package:http", 60.70), ("dio", 78.38), ("rhttp", 48.12)]),
        ("burst 126 GETs", [("nitro_http", 35.04), ("dart:io", 48.45), ("package:http", 61.06), ("dio", 96.09), ("rhttp", 50.40)]),
        ("256 MiB download", [("nitro_http", 1837.55), ("dart:io", 2471.90), ("package:http", 2374.70), ("dio", 2362.71), ("rhttp", 2097.63)]),
        ("128 MiB upload", [("nitro_http", 3995.48), ("dart:io", 4300.34), ("package:http", 4353.30), ("dio", 4295.72), ("rhttp", 4618.60)]),
        ("mixed workload", [("nitro_http", 121.27), ("dart:io", 125.11), ("package:http", 115.76), ("dio", 146.96), ("rhttp", 108.65)]),
    ],
    "Parallel (everything at once)": [
        ("small GET", [("nitro_http", 221.70), ("dart:io", 363.24), ("package:http", 1327.42), ("dio", 1608.81), ("rhttp", 569.71)]),
        ("burst 126 GETs", [("nitro_http", 32.80), ("dart:io", 47.82), ("package:http", 62.06), ("dio", 89.64), ("rhttp", 50.06)]),
        ("256 MiB download", [("nitro_http", 1861.75), ("dart:io", 2559.39), ("package:http", 2502.67), ("dio", 2516.82), ("rhttp", 2050.71)]),
        ("128 MiB upload", [("nitro_http", 4055.95), ("dart:io", 4280.13), ("package:http", 4375.41), ("dio", 4316.10), ("rhttp", 4616.41)]),
        ("mixed workload", [("nitro_http", 370.81), ("dart:io", 499.95), ("package:http", 799.63), ("dio", 839.41), ("rhttp", 447.87)]),
    ],
}


def fmt_wide(v):
    if v >= 1000:
        return f"{v / 1000:.2f} s"
    return fmt(v)


def modes_svg(mode):
    m = MODES[mode]
    cols = list(ANDROID_MODES)
    n_rows = len(ANDROID_MODES[cols[0]])
    pw, ph = 400, 148
    w = len(cols) * pw + (len(cols) + 1) * PAD
    header = 84
    h = header + n_rows * (ph + PAD) + PAD

    wins = sum(
        1
        for panels in ANDROID_MODES.values()
        for _, vals in panels
        if min(vals, key=lambda kv: kv[1])[0] == FOCUS
    )
    total = sum(len(p) for p in ANDROID_MODES.values())

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif">',
        f'<rect width="{w}" height="{h}" fill="{m["surface"]}" rx="8"/>',
        f'<text x="{PAD + 2}" y="26" font-size="15" font-weight="600" fill="{m["ink"]}">'
        f'Android — OnePlus 11 (Snapdragon 8 Gen 2, 16 GB), Android 16</text>',
        f'<text x="{PAD + 2}" y="43" font-size="11" fill="{m["ink2"]}">'
        f'p50 per dispatch mode, release, single run each — lower is better · '
        f'fastest in {wins} of {total} cells · '
        f'<tspan fill="{m["accent"]}" font-weight="600">▮ nitro_http</tspan> · ▮ other clients</text>',
    ]
    for ci, col in enumerate(cols):
        cx = PAD + ci * (pw + PAD)
        out.append(
            f'<text x="{cx + 6}" y="{header - 14}" font-size="13" font-weight="600" '
            f'fill="{m["ink"]}">{esc(col)}</text>')
        for ri, (scenario, values) in enumerate(ANDROID_MODES[col]):
            px, py = cx, header + ri * (ph + PAD)
            out.append(f'<rect x="{px}" y="{py}" width="{pw}" height="{ph}" fill="{m["panel"]}" rx="6"/>')
            out.append(f'<text x="{px + 10}" y="{py + 18}" font-size="12" font-weight="600" '
                       f'fill="{m["ink"]}">{esc(scenario)}</text>')
            ranked = sorted(values, key=lambda kv: kv[1])
            vmax = max(v for _, v in values)
            track = pw - LABEL_W - VALUE_W - 30
            for j, (client, v) in enumerate(ranked):
                y = py + 30 + j * (BAR_H + BAR_GAP)
                focus = client == FOCUS
                fill = m["accent"] if focus else m["gray"]
                bw = max(3, track * v / vmax)
                out.append(
                    f'<text x="{px + 10 + LABEL_W - 6}" y="{y + BAR_H - 3}" font-size="10.5" '
                    f'text-anchor="end" fill="{m["ink"] if focus else m["ink2"]}" '
                    f'font-weight="{600 if focus else 400}">{esc(client)}</text>')
                r = 4
                out.append(
                    f'<path d="M{px + 10 + LABEL_W} {y} h{bw - r} a{r} {r} 0 0 1 {r} {r} '
                    f'v{BAR_H - 2 * r} a{r} {r} 0 0 1 -{r} {r} h-{bw - r} z" fill="{fill}"/>')
                label = fmt_wide(v) + (" · fastest" if j == 0 else "")
                out.append(
                    f'<text x="{px + 14 + LABEL_W + bw}" y="{y + BAR_H - 3}" font-size="10.5" '
                    f'fill="{m["ink"] if j == 0 else m["ink2"]}" '
                    f'font-weight="{600 if j == 0 else 400}">{label}</text>')
    out.append("</svg>")
    return "\n".join(out)


if __name__ == "__main__":
    import pathlib
    doc = pathlib.Path(__file__).resolve().parent.parent / "doc"
    doc.mkdir(exist_ok=True)
    for key in DATA:
        for mode in MODES:
            path = doc / f"bench-{key}-{mode}.svg"
            path.write_text(platform_svg(key, mode))
            print(path.name)
    for mode in MODES:
        path = doc / f"bench-android-modes-{mode}.svg"
        path.write_text(modes_svg(mode))
        print(path.name)
