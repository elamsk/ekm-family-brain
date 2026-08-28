#!/usr/bin/env bash
# Shared helpers. Sourced by every script in this directory.
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/opt/hermes/data}"
BRAIN_REPO="${BRAIN_REPO:-/opt/hermes/workspace/family-brain}"
SYSTEM_REPO="${SYSTEM_REPO:-/opt/hermes/workspace/agent-system}"
HERMES_BIN="${HERMES_BIN:-docker exec hermes-gateway hermes}"

log() { printf '%s [%s] %s\n' "$(date -Is)" "${SCRIPT_NAME:-script}" "$*"; }

# Notify the family Telegram chat. Used ONLY for failures and things worth
# reading — see the silent-by-default rule in SOUL.md.
#
# `hermes send` is the framework's own delivery path: it reuses the gateway's
# configured platform credentials, needs no LLM and no agent loop, and works
# even when the gateway process is down (bot-token platforms). That is exactly
# what a failure notifier needs — it must survive the thing it reports on.
#
# Target syntax is `--to <platform>` for the home channel, or
# `--to telegram:<chat_id>` to pin a specific chat.
TELEGRAM_TARGET="${TELEGRAM_TARGET:-telegram}"
notify() {
  local msg="$1"
  if ! $HERMES_BIN send --to "$TELEGRAM_TARGET" --quiet "$msg" >/dev/null 2>&1; then
    log "WARNING: could not deliver Telegram notification: ${msg}"
    return 1
  fi
}

# Fail loudly to Telegram, then exit non-zero.
die() { log "ERROR: $*"; notify "⚠️ ${SCRIPT_NAME:-job} failed: $*" || true; exit 1; }
