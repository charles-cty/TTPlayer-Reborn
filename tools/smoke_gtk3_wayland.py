#!/usr/bin/env python3
"""Parse skinpreview --probe JSON and assert GTK3 / Wayland or X11 smoke."""

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
    ap.add_argument("--expect-backend", required=True, choices=("wayland", "x11", "win32"))
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
            notes.append(f"{name}: native size {nw}x{nh} (Wayland may hide origin)")

    snap = data.get("snap") or {}
    gap_after = snap.get("gap_after")
    snapped = bool(snap.get("snapped"))
    if args.expect_backend == "x11":
        if gap_after not in (0, -0, 0.0) and not snapped:
            msg = f"programmatic snap did not close gap (gap_after={gap_after})"
            if args.strict_snap:
                errors.append(msg)
            else:
                notes.append(msg)
    else:
        notes.append(
            f"wayland snap not required (gap_after={gap_after}, snapped={snapped})"
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
