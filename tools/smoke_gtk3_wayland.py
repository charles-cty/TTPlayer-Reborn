#!/usr/bin/env python3
"""Parse skinpreview --probe JSON and assert GTK3 XWayland/X11 smoke."""

from __future__ import annotations

import argparse
import json
import sys


def extract_json(text: str) -> dict:
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("no JSON object in probe output")
    return json.loads(text[start : end + 1])


def load_probe(path: str | None) -> dict:
    if path:
        with open(path, encoding="utf-8") as f:
            return extract_json(f.read())
    return extract_json(sys.stdin.read())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("probe_file", nargs="?", help="JSON from skinpreview --probe")
    ap.add_argument("--expect-backend", default="x11", choices=("x11", "win32"))
    ap.add_argument("--expect-widgetset", default="gtk3")
    ap.add_argument("--strict-snap", action="store_true")
    args = ap.parse_args()

    data = load_probe(args.probe_file)
    errors: list[str] = []
    notes: list[str] = []

    if not data.get("ok"):
        errors.append("ok is not true")
    if data.get("widgetset") != args.expect_widgetset:
        errors.append(
            f"widgetset={data.get('widgetset')!r} expected {args.expect_widgetset!r}"
        )
    if data.get("backend") != args.expect_backend:
        errors.append(
            f"backend={data.get('backend')!r} expected {args.expect_backend!r}"
        )

    expect_shape = args.expect_backend == "x11"
    if bool(data.get("shape_supported")) != expect_shape:
        errors.append(
            f"shape_supported={data.get('shape_supported')!r} expected {expect_shape}"
        )

    wins = data.get("windows") or {}
    for name in ("player", "equalizer", "lyric", "playlist"):
        w = wins.get(name) or {}
        if not w.get("present"):
            errors.append(f"{name}: not present")
            continue
        if not w.get("visible"):
            errors.append(f"{name}: not visible")
        lw, lh = w.get("lcl_width") or 0, w.get("lcl_height") or 0
        nw, nh = w.get("native_width") or 0, w.get("native_height") or 0
        if lw <= 0 or lh <= 0:
            errors.append(f"{name}: lcl size {lw}x{lh}")
        if nw <= 0 or nh <= 0:
            errors.append(f"{name}: native size {nw}x{nh}")
        elif abs(nw - lw) > 24 or abs(nh - lh) > 24:
            errors.append(
                f"{name}: native {nw}x{nh} vs LCL {lw}x{lh} (CSD/frame still on)"
            )
        if w.get("decorated"):
            errors.append(f"{name}: gtk_window decorated still true")
        if w.get("has_titlebar"):
            errors.append(f"{name}: CSD titlebar present")

    if data.get("backend") == "wayland":
        errors.append("backend=wayland; Linux target is XWayland/X11 only")

    if args.expect_backend == "x11" and not data.get("always_on_top_native"):
        errors.append("always_on_top_native is false")
    player = wins.get("player") or {}
    if args.expect_backend == "x11" and player.get("present") and not player.get(
        "ewmh_above"
    ):
        notes.append(
            "player keep_above not in _NET_WM_STATE "
            "(WM may ignore ABOVE, e.g. WSLg Weston)"
        )

    snap = data.get("snap") or {}
    gap_after = snap.get("gap_after")
    if args.expect_backend == "x11":
        if gap_after is None:
            errors.append("snap gap_after missing")
        elif abs(int(gap_after)) > 1:
            errors.append(
                f"programmatic snap did not close gap (gap_after={gap_after})"
            )

    print(
        "probe",
        json.dumps(
            {
                "backend": data.get("backend"),
                "widgetset": data.get("widgetset"),
                "gdk_display": data.get("gdk_display"),
                "shape_supported": data.get("shape_supported"),
                "skin": data.get("skin"),
                "snap": snap,
            },
            ensure_ascii=False,
        ),
    )
    for n in notes:
        print("NOTE:", n)
    if errors:
        for e in errors:
            print("FAIL:", e)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
