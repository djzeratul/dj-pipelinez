#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:?missing input}"

BASE="$(basename "$INPUT")"
STEM="${BASE%.*}"

QUEUE_DIR="/mnt/leviathan/data/upscale/incoming"
WORK_ROOT="/mnt/leviathan/data/upscale/work"
OUT_DIR="/mnt/leviathan/data/upscale/outgoing"
FAIL_DIR="/mnt/leviathan/data/upscale/failed"

REALSR_DIR="/opt/realesrgan-ncnn-vulkan"
REALSR="$REALSR_DIR/realesrgan-ncnn-vulkan"

# Conservative stable defaults for GTX 1080 Ti
MODEL_NAME="realesrgan-x4plus"
TILE_SIZE="256"
THREADS="1:1:1"

CQ="18"
PRESET="p5"

TARGET_W="3840"
TARGET_H="2160"

LOCKFILE="/mnt/leviathan/data/upscale/work/dj-pipelinez.lock"
mkdir -p /run

# Global single-worker lock
exec 9>"$LOCKFILE"
flock 9

# Input may already have been claimed by another process between scan and exec
if [[ ! -f "$INPUT" ]]; then
  echo "[worker] file no longer exists, skipping: $INPUT"
  exit 0
fi

mkdir -p "$WORK_ROOT" "$OUT_DIR" "$FAIL_DIR"

JOBDIR="$(mktemp -d "$WORK_ROOT/${STEM}.XXXX")"
FRAMES="$JOBDIR/frames"
UPSCALED="$JOBDIR/upscaled"
mkdir -p "$FRAMES" "$UPSCALED"

INPUT_WORK="$JOBDIR/$BASE"

cleanup() {
  rm -rf "$JOBDIR"
}
trap cleanup EXIT

echo "[worker] claiming $INPUT"

# Move file out of queue immediately so it cannot be picked up again
mv "$INPUT" "$INPUT_WORK"
INPUT="$INPUT_WORK"

echo "[worker] processing $INPUT"

FPS="$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=r_frame_rate \
  -of default=noprint_wrappers=1:nokey=1 "$INPUT" || echo "30/1")"

# 1. Extract frames
ffmpeg -hide_banner -y \
  -threads 6 \
  -i "$INPUT" \
  -vsync 0 \
  "$FRAMES/frame_%08d.png"

# 2. Upscale frames on GPU
TOTAL_FRAMES=$(ls "$FRAMES"/*.png | wc -l)
echo "[worker] total frames: $TOTAL_FRAMES"

START_TIME=$(date +%s)

(
  cd "$REALSR_DIR"

  if [[ "${DEBUG:-0}" == "1" ]]; then
    "$REALSR" \
      -i "$FRAMES" \
      -o "$UPSCALED" \
      -n "$MODEL_NAME" \
      -s 4 \
      -t "$TILE_SIZE" \
      -j "$THREADS"
  else
    "$REALSR" \
      -i "$FRAMES" \
      -o "$UPSCALED" \
      -n "$MODEL_NAME" \
      -s 4 \
      -t "$TILE_SIZE" \
      -j "$THREADS" \
      > /dev/null 2>&1
  fi
) &

UPSCALE_PID=$!

# progress loop
while kill -0 "$UPSCALE_PID" 2>/dev/null; do
  DONE=$(ls "$UPSCALED"/*.png 2>/dev/null | wc -l || echo 0)

  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))

  if [[ "$DONE" -gt 0 && "$ELAPSED" -gt 0 ]]; then
    FPS=$(awk "BEGIN { printf \"%.2f\", $DONE / $ELAPSED }")
    REMAINING=$((TOTAL_FRAMES - DONE))
    ETA=$(awk "BEGIN { if ($FPS > 0) printf \"%.0f\", $REMAINING / $FPS; else print 0 }")
  else
    FPS="0.00"
    ETA=0
  fi

  PCT=$(awk "BEGIN { if ($TOTAL_FRAMES > 0) printf \"%.2f\", ($DONE/$TOTAL_FRAMES)*100; else print 0 }")

  printf "[worker] %d / %d (%.2f%%) | %.2f fps | ETA: %02d:%02d\n" \
    "$DONE" "$TOTAL_FRAMES" "$PCT" "$FPS" \
    $((ETA/60)) $((ETA%60))

  sleep 2
done

wait "$UPSCALE_PID"

# 3. Validate upscale output
if [[ -z "$(ls -A "$UPSCALED" 2>/dev/null)" ]]; then
  echo "[worker] upscale failed: no output frames generated"
  mv "$INPUT" "$FAIL_DIR/" 2>/dev/null || true
  exit 1
fi

OUT="$OUT_DIR/${STEM}_4k.mp4"

# 4. Encode final output with NVENC
ffmpeg -hide_banner -y \
  -threads 6 \
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

echo "[worker] finished -> $OUT"