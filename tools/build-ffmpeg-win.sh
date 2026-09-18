#!/usr/bin/env bash
# Audio-only static FFmpeg for MinGW64. Invoked by tools/build-ffmpeg-win.ps1
# from an MSYS2 MINGW64 login shell. LGPL: no --enable-gpl, no extra codecs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/ffmpeg"
BUILD="$ROOT/build/windows/deps/ffmpeg-mingw64"
PREFIX="$BUILD/prefix"
STAMP="$PREFIX/share/ttcore-ffmpeg-id"
VERSION="n8.1.2"

if [[ ! -f "$SRC/configure" ]]; then
  echo "missing $SRC/configure — init the FFmpeg submodule (depth 1):" >&2
  echo "  git submodule update --init --depth 1 third_party/ffmpeg" >&2
  exit 1
fi

MINGW_PREFIX="${MINGW_PREFIX:-${MSYSTEM_PREFIX:-/mingw64}}"
export PATH="${MINGW_PREFIX}/bin:/usr/bin:${PATH:-}"
export PKG_CONFIG_PATH="${MINGW_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PKG_CONFIG="${MINGW_PREFIX}/bin/pkg-config"

if ! command -v gcc >/dev/null || ! command -v make >/dev/null; then
  echo "need MSYS2 mingw-w64 gcc and make on PATH" >&2
  exit 1
fi

enable_list() {
  local kind="$1"
  shift
  local n
  for n in "$@"; do
    CONFIG+=("--enable-${kind}=${n}")
  done
}

CONFIG=(
  --prefix="$PREFIX"
  --enable-static
  --disable-shared
  --disable-autodetect
  --disable-everything
  --disable-programs
  --disable-doc
  --disable-htmlpages
  --disable-manpages
  --disable-podpages
  --disable-txtpages
  --disable-avdevice
  --disable-avfilter
  --disable-swscale
  --disable-network
  --disable-pthreads
  --disable-x86asm
  --disable-debug
  --enable-avcodec
  --enable-avformat
  --enable-avutil
  --enable-swresample
  --enable-zlib
  --enable-iconv
  --arch=x86_64
  --target-os=mingw32
  --pkg-config-flags=--static
  --extra-cflags=-O2
)

enable_list protocol file pipe data fd concat

enable_list demuxer \
  mp3 aac mov flac ogg wav aiff asf asf_o ape wv tta tak \
  ac3 eac3 dts dtshd matroska caf au spdif w64 \
  amrnb amrwb dsf oma mpc mpc8 gsm avi mpegts mpegps xwma \
  mlp truehd concat data \
  pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be \
  pcm_f32le pcm_f32be pcm_f64le pcm_u8 pcm_s8 pcm_alaw pcm_mulaw

enable_list muxer \
  mp3 ipod mp4 mov flac ogg opus wav aiff asf au caf \
  matroska matroska_audio webm adts ac3 eac3 spdif w64 tta wv oma \
  pcm_s16le

enable_list decoder \
  mp3float mp3 mp2float mp2 mp1float mp1 \
  mp3adufloat mp3adu mp3on4float mp3on4 \
  aac aac_latm alac flac vorbis opus \
  wmav1 wmav2 wmapro wmalossless wmavoice \
  ape wavpack tta tak ac3 eac3 dca mlp truehd \
  amrnb amrwb gsm gsm_ms \
  atrac1 atrac3 atrac3p atrac3al atrac3pal atrac9 \
  cook nellymoser mpc7 mpc8 \
  dsd_lsbf dsd_msbf dsd_lsbf_planar dsd_msbf_planar \
  adpcm_ima_wav adpcm_ima_qt adpcm_ms adpcm_swf adpcm_yamaha \
  pcm_s16le pcm_s16be pcm_s16le_planar pcm_s16be_planar \
  pcm_s24le pcm_s24be pcm_s24le_planar \
  pcm_s32le pcm_s32be pcm_s32le_planar \
  pcm_s8 pcm_s8_planar pcm_u8 \
  pcm_f32le pcm_f32be pcm_f64le pcm_f64be \
  pcm_alaw pcm_mulaw pcm_vidc pcm_bluray pcm_dvd \
  pcm_u16le pcm_u16be pcm_u24le pcm_u24be pcm_u32le pcm_u32be

enable_list parser \
  aac aac_latm ac3 dca flac mpegaudio opus vorbis tak mlp cook gsm

enable_list bsf \
  aac_adtstoasc extract_extradata pcm_rechunk dca_core eac3_core truehd_core

ID="$(printf '%s\n' "$VERSION" "${CONFIG[@]}")"
if [[ -f "$PREFIX/lib/libavcodec.a" && -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$ID" ]]; then
  echo "[build-ffmpeg-win] prefix already up to date at $PREFIX"
  ls -l "$PREFIX/lib"/libav*.a "$PREFIX/lib"/libswresample.a
  exit 0
fi

mkdir -p "$BUILD"
cd "$BUILD"

echo "[build-ffmpeg-win] configure $SRC -> $PREFIX"
"$SRC/configure" "${CONFIG[@]}"

JOBS="${NUMBER_OF_PROCESSORS:-4}"
echo "[build-ffmpeg-win] make -j${JOBS}"
make -j"${JOBS}"
make install

mkdir -p "$(dirname "$STAMP")"
printf '%s\n' "$ID" > "$STAMP"

echo "[build-ffmpeg-win] installed:"
ls -l "$PREFIX/lib"/libav*.a "$PREFIX/lib"/libswresample.a
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --static --libs libavformat libavcodec libswresample libavutil
