#!/usr/bin/env bash
# 用用户目录下的 FPC + Lazarus 构建 pascal/ 工程（默认 GTK3 widgetset）。
# 环境：
#   FPC:          $HOME/opt/fpc/bin/fpc
#   Lazarus:      $HOME/opt/lazarus  （make lazbuild 之后）
#   LAZARUS_DIR / FPC / LCL_PLATFORM 可覆盖默认值。
#
# 用法：
#   tools/build-pascal-linux.sh              # ttdump + tests + skinpreview
#   tools/build-pascal-linux.sh ttplayer
#   tools/build-pascal-linux.sh --heaptrc    # 同上，HeapTrc 构建（-gh）
#   tools/build-pascal-linux.sh --heaptrc tests
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASCAL="$ROOT/pascal"
LAZDIR="${LAZARUS_DIR:-$HOME/opt/lazarus}"
FPCBIN="${FPC:-$HOME/opt/fpc/bin/fpc}"
WS="${LCL_PLATFORM:-gtk3}"
PROJECT=""
HEAPTRC=0

for arg in "$@"; do
  case "$arg" in
    --heaptrc|-heaptrc) HEAPTRC=1 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *) PROJECT="$arg" ;;
  esac
done

export PATH="$(dirname "$FPCBIN"):$PATH"

if [[ ! -x "$FPCBIN" ]]; then
  echo "找不到 fpc：$FPCBIN" >&2
  exit 1
fi
if [[ ! -x "$LAZDIR/lazbuild" ]]; then
  echo "找不到 lazbuild：$LAZDIR/lazbuild（先在 Lazarus 源码目录 make lazbuild）" >&2
  exit 1
fi

LAZBUILD=("$LAZDIR/lazbuild" --lazarusdir="$LAZDIR")
mkdir -p "$PASCAL/bin" \
  "$PASCAL/lib/ttdump/x86_64-linux" \
  "$PASCAL/lib/tests/x86_64-linux" \
  "$PASCAL/lib/skinpreview/x86_64-linux" \
  "$PASCAL/lib/ttplayer/x86_64-linux" \
  "$PASCAL/lib/ttdump_heaptrc/x86_64-linux" \
  "$PASCAL/lib/tests_heaptrc/x86_64-linux" \
  "$PASCAL/lib/skinpreview_heaptrc/x86_64-linux" \
  "$PASCAL/lib/ttplayer_heaptrc/x86_64-linux"

echo "[build-pascal-linux] 注册 BGRABitmap 包"
"${LAZBUILD[@]}" --add-package-link "$PASCAL/vendor/bgrabitmap/bgrabitmap/bgrabitmappack4nolcl.lpk"
"${LAZBUILD[@]}" --add-package-link "$PASCAL/vendor/bgrabitmap/bgrabitmap/bgrabitmappack.lpk"
"${LAZBUILD[@]}" --ws=nogui "$PASCAL/vendor/bgrabitmap/bgrabitmap/bgrabitmappack4nolcl.lpk"
"${LAZBUILD[@]}" --ws="$WS" "$PASCAL/vendor/bgrabitmap/bgrabitmap/bgrabitmappack.lpk"

projects=(ttdump tests skinpreview)
if [[ -n "$PROJECT" ]]; then
  projects=("$PROJECT")
fi

for proj in "${projects[@]}"; do
  lpi="$PASCAL/${proj}.lpi"
  if [[ ! -f "$lpi" ]]; then
    echo "找不到工程：$lpi" >&2
    exit 1
  fi
  extra=()
  case "$proj" in
    skinpreview|ttplayer) extra+=(--ws="$WS") ;;
  esac
  if [[ "$HEAPTRC" -eq 1 ]]; then
    extra+=(--bm=HeapTrc)
    echo "[build-pascal-linux] HeapTrc 构建 $proj ${extra[*]-}"
  else
    echo "[build-pascal-linux] 构建 $proj ${extra[*]-}"
  fi
  "${LAZBUILD[@]}" "${extra[@]}" "$lpi"
done

echo "[build-pascal-linux] 完成"
if [[ "$HEAPTRC" -eq 1 ]]; then
  echo "[build-pascal-linux] HeapTrc 产物：pascal/bin/*_heaptrc ；报告默认写到同名 .heaptrc"
  echo "[build-pascal-linux] HEAPTRACEFILE=... HEAPTRC_KEEP_RELEASED=1 可覆盖"
fi
