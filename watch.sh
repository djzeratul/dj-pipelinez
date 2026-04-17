#!/usr/bin/env bash
set -euo pipefail

WATCH_DIR="/mnt/leviathan/data/upscale/incoming"
PROCESS="/srv/dj-pipelinez/process.sh"

echo "[watcher] watching $WATCH_DIR"

is_finished_copy() {
  local f="$1"
  local s1 s2
  s1=$(stat -c%s "$f" 2>/dev/null || echo 0)
  sleep 3
  s2=$(stat -c%s "$f" 2>/dev/null || echo 0)
  [[ "$s1" -gt 0 && "$s1" -eq "$s2" ]]
}

inotifywait -m -e close_write,moved_to --format '%w%f' "$WATCH_DIR" | while read -r file; do
  [[ -f "$file" ]] || continue

  case "$file" in
    *.mp4|*.mov|*.mkv|*.avi|*.webm)
      echo "[watcher] detected $file"
      if is_finished_copy "$file"; then
        "$PROCESS" "$file" || true
      else
        echo "[watcher] skipping incomplete file: $file"
      fi
      ;;
    *)
      echo "[watcher] ignoring $file"
      ;;
  esac
done