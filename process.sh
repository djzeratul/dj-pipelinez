#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:?missing input}"

BASE="$(basename "$INPUT")"
STEM="${BASE%.*}"

WORK_ROOT="/mnt/leviathan/data/upscale/work"
OUT_DIR="/mnt/leviathan/data/upscale/outgoing"
FAIL_DIR="/mnt/leviathan/data/upscale/failed"

REALSR_DIR="/opt/realesrgan-ncnn-vulkan"
REALSR="$REALSR_DIR/realesrgan-ncnn-vulkan"

CQ=18
PRESET="p5"

TARGET_W=3840
TARGET_H=2160

JOBDIR="$(mktemp -d "$WORK_ROOT/${STEM}.XXXX")"
FRAMES="$JOBDIR/frames"
UPSCALED="$JOBDIR/upscaled"

mkdir -p "$FRAMES" "$UPSCALED"

cleanup() {
  rm -rf "$JOBDIR"
}
trap cleanup EXIT

echo "[worker] processing $INPUT"

FPS=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=r_frame_rate \
  -of default=noprint_wrappers=1:nokey=1 "$INPUT" || echo "30/1")

# extract frames
ffmpeg -hide_banner -y \
  -i "$INPUT" \
  -vsync 0 \
  "$FRAMES/frame_%08d.png"

# upscale
(
  cd "$REALSR_DIR"
  "$REALSR" \
    -i "$FRAMES" \
    -o "$UPSCALED" \
    -n realesrgan-x4plus \
    -s 4 \
    -t 512
)

if [[ -z "$(ls -A "$UPSCALED" 2>/dev/null)" ]]; then
  echo "[worker] upscale failed"
  mv "$INPUT" "$FAIL_DIR/" 2>/dev/null || true
  exit 1
fi

OUT="$OUT_DIR/${STEM}_4k.mp4"

# encode (NVENC)
ffmpeg -hide_banner -y \
  -framerate "$FPS" \
  -i "$UPSCALED/frame_%08d.png" \
  -i "$INPUT" \
  -map 0:v:0 \
  -map 1:a? \
  -c:v hevc_nvenc \
  -preset "$PRESET" \
  -cq "$CQ" \
  -pix_fmt yuv420p \
  -vf "scale=${TARGET_W}:${TARGET_H}:force_original_aspect_ratio=decrease,pad=${TARGET_W}:${TARGET_H}:(ow-iw)/2:(oh-ih)/2" \
  -c:a copy \
  -shortest \
  "$OUT"

echo "[worker] finished → $OUT"