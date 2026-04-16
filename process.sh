#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:?missing input file}"

WATCH_DIR="${WATCH_DIR:-/watch/incoming}"
OUTPUT_DIR="${OUTPUT_DIR:-/watch/outgoing}"
FAILED_DIR="${FAILED_DIR:-/watch/failed}"
WORK_DIR="${WORK_DIR:-/watch/work}"

MODEL_NAME="${MODEL_NAME:-realesrgan-x4plus}"
TILE_SIZE="${TILE_SIZE:-512}"
TARGET_WIDTH="${TARGET_WIDTH:-3840}"
TARGET_HEIGHT="${TARGET_HEIGHT:-2160}"
CRF="${CRF:-17}"
PRESET="${PRESET:-slow}"

BIN="/opt/realesrgan/realesrgan-ncnn-vulkan"

mkdir -p "$OUTPUT_DIR" "$FAILED_DIR" "$WORK_DIR"

base="$(basename "$INPUT")"
stem="${base%.*}"

lock="/state/${stem}.lock"
if [[ -e "$lock" ]]; then
  echo "[worker] lock exists, skipping: $INPUT"
  exit 0
fi
touch "$lock"

jobdir="$(mktemp -d "$WORK_DIR/${stem}.XXXXXX")"
frames="$jobdir/frames"
upscaled="$jobdir/upscaled"
mkdir -p "$frames" "$upscaled"

cleanup() {
  rm -f "$lock"
  rm -rf "$jobdir"
}
trap cleanup EXIT

echo "[worker] processing: $INPUT"

# Probe FPS from source so remux stays sane
fps="$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=r_frame_rate \
  -of default=noprint_wrappers=1:nokey=1 "$INPUT")"

if [[ -z "$fps" ]]; then
  fps="30/1"
fi

# Extract source frames
ffmpeg -hide_banner -y \
  -i "$INPUT" \
  -vsync 0 \
  "$frames/frame_%08d.png"

# Upscale frames with Real-ESRGAN
"$BIN" \
  -i "$frames" \
  -o "$upscaled" \
  -n "$MODEL_NAME" \
  -s 4 \
  -t "$TILE_SIZE"

# Rebuild video, preserve source audio if present, export exact UHD
# The scale+pad step gives you literal 3840x2160 output.
tmp_video="$jobdir/${stem}_video.mp4"
final_video="$OUTPUT_DIR/${stem}_4k.mp4"

ffmpeg -hide_banner -y \
  -framerate "$fps" \
  -i "$upscaled/frame_%08d.png" \
  -i "$INPUT" \
  -map 0:v:0 \
  -map 1:a? \
  -c:v libx264 \
  -preset "$PRESET" \
  -crf "$CRF" \
  -pix_fmt yuv420p \
  -vf "scale=${TARGET_WIDTH}:${TARGET_HEIGHT}:force_original_aspect_ratio=decrease,pad=${TARGET_WIDTH}:${TARGET_HEIGHT}:(ow-iw)/2:(oh-ih)/2" \
  -c:a copy \
  -shortest \
  "$final_video"

echo "[worker] finished: $final_video"
