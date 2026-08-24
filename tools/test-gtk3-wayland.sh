#!/usr/bin/env bash
# GTK3 + Wayland / X11（Xwayland）探测：FPCUnit + skinpreview --probe。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${FPC:+$(dirname "$FPC"):}${PATH:-}"
export PATH="${HOME}/opt/fpc/bin:$PATH"
export NO_AT_BRIDGE=1

TESTS="$ROOT/pascal/bin/tests"
PREVIEW="$ROOT/pascal/bin/skinpreview"
OUTDIR="$ROOT/tests/artifacts/gtk3"
mkdir -p "$OUTDIR"

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

run_probe() {
  local backend="$1"
  local json="$OUTDIR/probe-${backend}.json"
  echo "[test-gtk3] skinpreview --probe GDK_BACKEND=$backend"
  # GTK 诊断走 stderr；JSON 同时写文件，避免混进 LCL 文本。
  if ! GDK_BACKEND="$backend" "$PREVIEW" --probe --probe-out "$json" \
      >"$OUTDIR/probe-${backend}.stdout" \
      2>"$OUTDIR/probe-${backend}.stderr"; then
    echo "skinpreview --probe 退出码非零（backend=$backend）" >&2
    tail -n 40 "$OUTDIR/probe-${backend}.stderr" >&2 || true
    exit 1
  fi
  # LCL GTK3 在未映射窗口上会刷 gdk_pixbuf_get_from_surface 的 0 尺寸 CRITICAL；
  # 那不是我们的 X11 误调用。只把 gdk_x11_* 打到非 X11 GdkWindow 当失败。
  # gtk_widget_get_window + GTK_IS_WIDGET 失败 = 把 TGtk3Widget 当成了 GtkWidget*。
  if grep -E 'gdk_x11_window_get_xid|gdk_x11_display_get_xdisplay|GDK_IS_X11_|gtk_widget_get_window: assertion' \
      "$OUTDIR/probe-${backend}.stderr" >/dev/null 2>&1; then
    echo "stderr 含 gdk_x11_* 或 gtk_widget_get_window CRITICAL（句柄转换错误）" >&2
    grep -E 'gdk_x11_|GDK_IS_X11_|gtk_widget_get_window' "$OUTDIR/probe-${backend}.stderr" >&2
    exit 1
  fi
  python3 "$ROOT/tools/smoke_gtk3_wayland.py" --expect-backend "$backend" "$json"
}

run_probe wayland
run_probe x11

echo "[test-gtk3] 全部通过"
echo "产物：$OUTDIR"
