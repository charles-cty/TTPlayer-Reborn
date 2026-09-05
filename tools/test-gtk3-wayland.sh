#!/usr/bin/env bash
# GTK3 + XWayland / 原生 X11 探测：FPCUnit + skinpreview --probe。
# 原生 Wayland 客户端不在支持范围；二进制会强制 GDK_BACKEND=x11。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${FPC:-}" ]]; then
  export PATH="$(dirname "$FPC"):${PATH:-}"
fi
export NO_AT_BRIDGE=1
export GDK_BACKEND=x11
export GTK_CSD=0

TESTS="$ROOT/pascal/bin/tests"
PREVIEW="$ROOT/pascal/bin/skinpreview"
OUTDIR="$ROOT/tests/artifacts/gtk3"
mkdir -p "$OUTDIR"

if [[ -z "${DISPLAY:-}" ]]; then
  echo "需要 X11 DISPLAY（XWayland 或 Xorg）。原生 Wayland 不支持。" >&2
  exit 1
fi

if [[ ! -x "$TESTS" ]]; then
  echo "找不到 $TESTS，先运行 tools/build-pascal-linux.sh" >&2
  exit 1
fi
if [[ ! -x "$PREVIEW" ]]; then
  echo "找不到 $PREVIEW，先运行 tools/build-pascal-linux.sh" >&2
  exit 1
fi

echo "[test-gtk3] FPCUnit"
"$TESTS" -a --format=plain

json="$OUTDIR/probe-x11.json"
echo "[test-gtk3] skinpreview --probe (XWayland/X11)"
if ! "$PREVIEW" --probe --probe-out "$json" \
    >"$OUTDIR/probe-x11.stdout" \
    2>"$OUTDIR/probe-x11.stderr"; then
  echo "skinpreview --probe 退出码非零" >&2
  tail -n 40 "$OUTDIR/probe-x11.stderr" >&2 || true
  exit 1
fi

if grep -E 'gdk_x11_window_get_xid|gdk_x11_display_get_xdisplay|GDK_IS_X11_|gtk_widget_get_window: assertion' \
    "$OUTDIR/probe-x11.stderr" >/dev/null 2>&1; then
  echo "stderr 含 gdk_x11_* 或 gtk_widget_get_window CRITICAL（句柄转换错误）" >&2
  grep -E 'gdk_x11_|GDK_IS_X11_|gtk_widget_get_window' "$OUTDIR/probe-x11.stderr" >&2
  exit 1
fi

python3 "$ROOT/tools/smoke_gtk3_wayland.py" --expect-backend x11 "$json"

scale2="$OUTDIR/probe-x11-scale2.json"
echo "[test-gtk3] skinpreview --probe (GDK_SCALE=2)"
if ! timeout 60 env GDK_SCALE=2 GDK_DPI_SCALE=1 "$PREVIEW" --probe --probe-out "$scale2" \
    >"$OUTDIR/probe-x11-scale2.stdout" \
    2>"$OUTDIR/probe-x11-scale2.stderr"; then
  echo "GDK_SCALE=2 probe 退出码非零或超时" >&2
  tail -n 40 "$OUTDIR/probe-x11-scale2.stderr" >&2 || true
  exit 1
fi
python3 "$ROOT/tools/smoke_gtk3_wayland.py" --expect-backend x11 "$scale2"

echo "[test-gtk3] 全部通过"
echo "产物：$OUTDIR"
