#!/usr/bin/env bash
set -euo pipefail

WATCH_DIR="${WATCH_DIR:-/watch/incoming}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

mkdir -p "$WATCH_DIR"

echo "[watcher] watching $WATCH_DIR"

process_existing() {
  shopt -s nullglob
  for f in "$WATCH_DIR"/*; do
    [[ -f "$f" ]] || continue
    /usr/local/bin/process.sh "$f" || true
  done
}

is_probably_finished_copy() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local s1 s2
  s1=$(stat -c%s "$f" 2>/dev/null || echo 0)
  sleep 3
  s2=$(stat -c%s "$f" 2>/dev/null || echo 0)
  [[ "$s1" -gt 0 && "$s1" -eq "$s2" ]]
}

process_existing

inotifywait -m -e close_write,moved_to --format '%w%f' "$WATCH_DIR" | while read -r file; do
  [[ -f "$file" ]] || continue

  case "$file" in
    *.mp4|*.mov|*.mkv|*.avi|*.webm)
      echo "[watcher] detected $file"
      if is_probably_finished_copy "$file"; then
        /usr/local/bin/process.sh "$file" || true
      else
        echo "[watcher] file still changing, skipping for now: $file"
      fi
      ;;
    *)
      echo "[watcher] ignoring unsupported file: $file"
      ;;
  esac
done
