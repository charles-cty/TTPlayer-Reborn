#!/usr/bin/env bash
# Build libttcore.so with distro FFmpeg + SDL2 (pkg-config).
#
#   sudo apt install cmake g++ pkg-config \
#     libavformat-dev libavcodec-dev libavutil-dev libswresample-dev libsdl2-dev
#
#   tools/build-ttcore-linux.sh              # Debug (default)
#   tools/build-ttcore-linux.sh --config Profile
#   tools/build-ttcore-linux.sh Release
#
# Does not use a kitchen-sink FFmpeg prefix. Runtime files go to build/linux/pascal/<config>.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${TTCORE_CONFIG:-Debug}"

usage() { sed -n '2,14p' "$0"; }

normalize_config() {
  case "$1" in
    Debug|debug) echo Debug ;;
    Release|release) echo Release ;;
    Profile|profile) echo Profile ;;
    RelWithDebInfo) echo RelWithDebInfo ;;
    *)
      echo "unknown config: $1 (want Debug|Release|Profile)" >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --config=*)
      CONFIG="$(normalize_config "${1#--config=}")"
      shift
      ;;
    --config|-C)
      if [[ $# -lt 2 ]]; then
        echo "build-ttcore-linux.sh: $1 needs Debug|Release|Profile" >&2
        exit 1
      fi
      CONFIG="$(normalize_config "$2")"
      shift 2
      ;;
    Debug|debug|Release|release|Profile|profile|RelWithDebInfo)
      CONFIG="$(normalize_config "$1")"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cfg_lc="$(printf '%s' "$CONFIG" | tr '[:upper:]' '[:lower:]')"
BUILD="${TTCORE_BUILD_DIR:-$ROOT/build/linux/ttcore/$cfg_lc}"

need=(libavformat libavcodec libavutil libswresample sdl2)
missing=()
for pc in "${need[@]}"; do
  if ! pkg-config --exists "$pc"; then
    missing+=("$pc")
  fi
done
if ((${#missing[@]})); then
  echo "pkg-config missing: ${missing[*]}" >&2
  echo "Install with:" >&2
  echo "  sudo apt install cmake g++ pkg-config \\" >&2
  echo "    libavformat-dev libavcodec-dev libavutil-dev libswresample-dev libsdl2-dev" >&2
  exit 1
fi

echo "[build-ttcore-linux] cmake $BUILD (BUILD_QT_APP=OFF CMAKE_BUILD_TYPE=$CONFIG)"
cmake -S "$ROOT" -B "$BUILD" -DBUILD_QT_APP=OFF "-DCMAKE_BUILD_TYPE=$CONFIG"
echo "[build-ttcore-linux] cmake --build ttcore ttcore_probe"
cmake --build "$BUILD" --target ttcore ttcore_probe -j"$(nproc 2>/dev/null || echo 4)"

runtime="$ROOT/build/linux/pascal/$cfg_lc"
mkdir -p "$runtime"
so="$BUILD/libttcore.so"
if [[ ! -f "$so" ]]; then
  echo "未生成 $so" >&2
  exit 1
fi
cp "$so" "$runtime/"
cp "$BUILD/ttcore_probe" "$runtime/"
echo "[build-ttcore-linux] $so ($(wc -c < "$so") bytes)  config=$CONFIG"
echo "[build-ttcore-linux] ffmpeg $(pkg-config --modversion libavformat)  sdl2 $(pkg-config --modversion sdl2)"
