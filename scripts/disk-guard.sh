#!/usr/bin/env bash
# Phase 9.2 — alert if any log exceeds 1 GB or the disk crosses 85%.
# Truncates known-runaway logs. Silent unless something is wrong.
SCRIPT_NAME="disk-guard"
source "$(dirname "$0")/lib.sh"

LOG_LIMIT_BYTES=$((1024 * 1024 * 1024))   # 1 GB
DISK_LIMIT_PCT=85
problems=()

# --- oversized log files ---
while IFS= read -r f; do
  [ -z "$f" ] && continue
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "$size" -gt "$LOG_LIMIT_BYTES" ]; then
    human=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")
    problems+=("log ${f} was ${human} — truncated to last 10k lines")
    tmp="$(mktemp)"; tail -n 10000 "$f" > "$tmp" && cat "$tmp" > "$f" && rm -f "$tmp"
    log "truncated ${f} (was ${human})"
  fi
done < <(find "$HERMES_HOME" /var/lib/docker/containers -type f -name '*.log' 2>/dev/null)

# --- disk usage ---
used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "${used:-0}" -ge "$DISK_LIMIT_PCT" ]; then
  problems+=("disk at ${used}% (threshold ${DISK_LIMIT_PCT}%)")
  # Reclaim the cheap, safe things before shouting.
  docker image prune -f >/dev/null 2>&1 || true
  find "$HERMES_HOME/checkpoints" -type f -mtime +14 -delete 2>/dev/null || true
  after=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  problems+=("after automatic cleanup: ${after}%")
fi

if [ ${#problems[@]} -gt 0 ]; then
  notify "🧹 Disk guard on $(hostname):
$(printf '  • %s\n' "${problems[@]}")"
  log "reported ${#problems[@]} problem(s)"
else
  log "ok — nothing to report"   # silent by default: no Telegram message
fi
