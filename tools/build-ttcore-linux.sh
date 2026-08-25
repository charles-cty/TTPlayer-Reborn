#!/usr/bin/env bash
# Build libttcore.so with distro FFmpeg + SDL2 (pkg-config).
#
#   sudo apt install cmake g++ pkg-config \
#     libavformat-dev libavcodec-dev libavutil-dev libswresample-dev libsdl2-dev
#
# Does not use a kitchen-sink FFmpeg prefix. Copy goes to pascal/bin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${TTCORE_BUILD_DIR:-$ROOT/build-ttcore}"

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

echo "[build-ttcore-linux] cmake $BUILD (BUILD_QT_APP=OFF)"
cmake -S "$ROOT" -B "$BUILD" -DBUILD_QT_APP=OFF
echo "[build-ttcore-linux] cmake --build ttcore ttcore_probe"
cmake --build "$BUILD" --target ttcore ttcore_probe -j"$(nproc 2>/dev/null || echo 4)"

so="$ROOT/pascal/bin/libttcore.so"
if [[ ! -f "$so" ]]; then
  echo "未生成 $so" >&2
  exit 1
fi
echo "[build-ttcore-linux] $so ($(wc -c < "$so") bytes)"
echo "[build-ttcore-linux] ffmpeg $(pkg-config --modversion libavformat)  sdl2 $(pkg-config --modversion sdl2)"
