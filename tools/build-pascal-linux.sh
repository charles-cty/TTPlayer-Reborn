#!/usr/bin/env bash
# 用 FPC + Lazarus 构建 pascal/ 工程（默认 GTK3 widgetset）。
# 环境变量（不写死安装路径）：
#   FPC           fpc 可执行文件（否则 PATH 上的 fpc）
#   LAZARUS_DIR   Lazarus 根目录（含 lazbuild）
#   LAZBUILD      lazbuild 可执行文件（否则 $LAZARUS_DIR/lazbuild 或 PATH）
#   LCL_PLATFORM  widgetset，默认 gtk3
#
# 用法：
#   tools/build-pascal-linux.sh                    # Debug：ttdump + tests + skinpreview + ttplayer
#   tools/build-pascal-linux.sh ttplayer           # 只编主程序
#   tools/build-pascal-linux.sh --config Debug
#   tools/build-pascal-linux.sh --heaptrc          # HeapTrc 构建（-gh）
#   tools/build-pascal-linux.sh --heaptrc tests
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASCAL="$ROOT/pascal"
WS="${LCL_PLATFORM:-gtk3}"
PROJECT=""
CONFIG="Debug"

resolve_fpc() {
  if [[ -n "${FPC:-}" ]]; then
    printf '%s\n' "$FPC"
    return
  fi
  if command -v fpc >/dev/null 2>&1; then
    command -v fpc
    return
  fi
  echo "找不到 fpc。请设置 FPC（fpc 可执行文件路径）或把 fpc 加入 PATH。" >&2
  exit 1
}

resolve_lazbuild() {
  if [[ -n "${LAZBUILD:-}" ]]; then
    printf '%s\n' "$LAZBUILD"
    return
  fi
  if [[ -n "${LAZARUS_DIR:-}" ]]; then
    printf '%s\n' "$LAZARUS_DIR/lazbuild"
    return
  fi
  if command -v lazbuild >/dev/null 2>&1; then
    command -v lazbuild
    return
  fi
  echo "找不到 lazbuild。请设置 LAZARUS_DIR 或 LAZBUILD，或把 lazbuild 加入 PATH。" >&2
  exit 1
}

resolve_lazdir() {
  if [[ -n "${LAZARUS_DIR:-}" ]]; then
    printf '%s\n' "$LAZARUS_DIR"
    return
  fi
  dirname "$(resolve_lazbuild)"
}

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
      sed -n '2,14p' "$0"
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

FPCBIN="$(resolve_fpc)"
LAZDIR="$(resolve_lazdir)"
LAZBUILD_BIN="$(resolve_lazbuild)"
export PATH="$(dirname "$FPCBIN"):$PATH"
config_lc="$(printf '%s' "$CONFIG" | tr '[:upper:]' '[:lower:]')"
runtime="$ROOT/build/linux/pascal/$config_lc"
mkdir -p "$runtime"

if [[ ! -x "$FPCBIN" ]]; then
  echo "找不到 fpc：$FPCBIN（设置 FPC）" >&2
  exit 1
fi
if [[ ! -d "$LAZDIR" ]]; then
  echo "找不到 Lazarus 目录：$LAZDIR（设置 LAZARUS_DIR）" >&2
  exit 1
fi
if [[ ! -x "$LAZBUILD_BIN" ]]; then
  echo "找不到 lazbuild：$LAZBUILD_BIN（设置 LAZARUS_DIR 或 LAZBUILD）" >&2
  exit 1
fi

echo "[build-pascal-linux] fpc=$FPCBIN  lazbuild=$LAZBUILD_BIN  lazarusdir=$LAZDIR"
LAZBUILD=("$LAZBUILD_BIN" --lazarusdir="$LAZDIR")

echo "[build-pascal-linux] 注册 BGRABitmap 包"
"${LAZBUILD[@]}" --add-package-link "$PASCAL/vendor/bgrabitmap/bgrabitmap/bgrabitmappack4nolcl.lpk"
"${LAZBUILD[@]}" --add-package-link "$PASCAL/vendor/bgrabitmap/bgrabitmap/bgrabitmappack.lpk"
"${LAZBUILD[@]}" --ws=nogui "$PASCAL/vendor/bgrabitmap/bgrabitmap/bgrabitmappack4nolcl.lpk"
"${LAZBUILD[@]}" --ws="$WS" "$PASCAL/vendor/bgrabitmap/bgrabitmap/bgrabitmappack.lpk"

projects=(ttdump tests skinpreview ttplayer)
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
  objdir="$ROOT/build/linux/pascal/obj/$proj/$config_lc/x86_64-linux"
  mkdir -p "$objdir"
  extra+=(--opt="-FE$runtime" --opt="-FU$objdir")
  echo "[build-pascal-linux] $CONFIG 构建 $proj ${extra[*]}"
  "${LAZBUILD[@]}" "${extra[@]}" "$lpi"
done

echo "[build-pascal-linux] 完成 ($CONFIG)"
if [[ "$CONFIG" == "HeapTrc" ]]; then
  echo "[build-pascal-linux] HeapTrc 产物：build/linux/pascal/heaptrc/*_heaptrc；报告默认写到同名 .heaptrc"
  echo "[build-pascal-linux] HEAPTRACEFILE=... HEAPTRC_KEEP_RELEASED=1 可覆盖"
fi
