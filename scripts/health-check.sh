#!/usr/bin/env bash
# Phase 9.3 — twice daily. Services up, disk ok, cron ran, backups fresh.
# Messages Telegram ONLY on problems.
SCRIPT_NAME="health-check"
source "$(dirname "$0")/lib.sh"

problems=()

# --- containers running? ---
for c in hermes-gateway hermes-webui; do
  state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
  [ "$state" = "running" ] || problems+=("container ${c} is ${state}")
done

# --- disk ---
used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "${used:-0}" -ge 85 ] && problems+=("disk at ${used}%")

# --- did scheduled jobs actually run? a scheduler that silently stopped is
#     the failure mode this whole check exists for ---
if ! $HERMES_BIN cron status >/dev/null 2>&1; then
  problems+=("hermes cron scheduler is not responding")
else
  failed=$($HERMES_BIN cron runs --limit 20 2>/dev/null | grep -ciE '\bfail|error' || true)
  [ "${failed:-0}" -gt 0 ] && problems+=("${failed} of the last 20 cron runs failed")
fi

# --- backup freshness ---
# nightly git: brain repo should have a commit in the last 36h
if [ -d "$BRAIN_REPO/.git" ]; then
  last=$(git -C "$BRAIN_REPO" log -1 --format=%ct 2>/dev/null || echo 0)
  age_h=$(( ($(date +%s) - last) / 3600 ))
  [ "$age_h" -gt 36 ] && problems+=("brain repo last commit was ${age_h}h ago")
fi
# weekly encrypted: newest archive should be < 9 days old
newest=$(find "${BACKUP_STAGE:-/opt/hermes/backups}" -name 'hermes-home-*.zip.gpg' -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
if [ -n "${newest:-}" ]; then
  age_d=$(( ($(date +%s) - newest) / 86400 ))
  [ "$age_d" -gt 9 ] && problems+=("newest encrypted backup is ${age_d} days old")
else
  problems+=("no encrypted backup archive found")
fi

if [ ${#problems[@]} -gt 0 ]; then
  notify "🚑 Health check on $(hostname):
$(printf '  • %s\n' "${problems[@]}")"
  exit 1
fi
log "all checks passed — staying silent"
