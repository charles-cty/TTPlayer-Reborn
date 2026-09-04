#!/usr/bin/env bash
# 用用户目录下的 FPC + Lazarus 构建 pascal/ 工程（默认 GTK3 widgetset）。
# 环境：
#   FPC:          $HOME/opt/fpc/bin/fpc
#   Lazarus:      $HOME/opt/lazarus  （make lazbuild 之后）
#   LAZARUS_DIR / FPC / LCL_PLATFORM 可覆盖默认值。
#
# 用法：
#   tools/build-pascal-linux.sh                    # Debug：ttdump + tests + skinpreview
#   tools/build-pascal-linux.sh ttplayer
#   tools/build-pascal-linux.sh --config Debug
#   tools/build-pascal-linux.sh --heaptrc          # HeapTrc 构建（-gh）
#   tools/build-pascal-linux.sh --heaptrc tests
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASCAL="$ROOT/pascal"
LAZDIR="${LAZARUS_DIR:-$HOME/opt/lazarus}"
FPCBIN="${FPC:-$HOME/opt/fpc/bin/fpc}"
WS="${LCL_PLATFORM:-gtk3}"
PROJECT=""
CONFIG="Debug"

normalize_config() {
  case "$1" in
    Debug|debug) echo Debug ;;
    Release|release) echo Release ;;
    Profile|profile) echo Profile ;;
    HeapTrc|heaptrc|HeapTrace) echo HeapTrc ;;
    *)
      echo "unknown config: $1 (want Debug|Release|Profile|HeapTrc)" >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --heaptrc|-heaptrc)
      CONFIG=HeapTrc
      shift
      ;;
    --config=*)
      CONFIG="$(normalize_config "${1#--config=}")"
      shift
      ;;
    --config)
      if [[ $# -lt 2 ]]; then
        echo "build-pascal-linux.sh: --config needs Debug|Release|Profile|HeapTrc" >&2
        exit 1
      fi
      CONFIG="$(normalize_config "$2")"
      shift 2
      ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    Debug|Release|Profile|HeapTrc)
      CONFIG="$(normalize_config "$1")"
      shift
      ;;
    *)
      PROJECT="$1"
      shift
      ;;
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
mkdir -p "$PASCAL/bin"
for proj in ttdump tests skinpreview ttplayer; do
  mkdir -p "$PASCAL/lib/${proj}/Debug/x86_64-linux" \
    "$PASCAL/lib/${proj}/Release/x86_64-linux" \
    "$PASCAL/lib/${proj}/Profile/x86_64-linux" \
    "$PASCAL/lib/${proj}_heaptrc/x86_64-linux"
done

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
  extra=(--bm="$CONFIG")
  case "$proj" in
    skinpreview|ttplayer) extra+=(--ws="$WS") ;;
  esac
  echo "[build-pascal-linux] $CONFIG 构建 $proj ${extra[*]}"
  "${LAZBUILD[@]}" "${extra[@]}" "$lpi"
done

echo "[build-pascal-linux] 完成 ($CONFIG)"
if [[ "$CONFIG" == "HeapTrc" ]]; then
  echo "[build-pascal-linux] HeapTrc 产物：pascal/bin/*_heaptrc ；报告默认写到同名 .heaptrc"
  echo "[build-pascal-linux] HEAPTRACEFILE=... HEAPTRC_KEEP_RELEASED=1 可覆盖"
fi
