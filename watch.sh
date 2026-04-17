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

process_pending() {
  shopt -s nullglob

  for file in "$WATCH_DIR"/*; do
    [[ -f "$file" ]] || continue

    case "$file" in
      *.mp4|*.mov|*.mkv|*.avi|*.webm)
        if is_finished_copy "$file"; then
          echo "[watcher] found ready file: $file"
          "$PROCESS" "$file" || true
        else
          echo "[watcher] file still copying: $file"
        fi
        ;;
      *)
        echo "[watcher] ignoring unsupported file: $file"
        ;;
    esac
  done
}

# Process any files already present when the service starts
process_pending

# Watch for new/finished copies and then sweep the queue
inotifywait -m -e close_write,moved_to --format '%w%f' "$WATCH_DIR" | while read -r _; do
  process_pending
done