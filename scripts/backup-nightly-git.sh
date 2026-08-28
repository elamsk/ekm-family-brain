#!/usr/bin/env bash
# Phase 4.3 / 5.3 — nightly commit+push of the markdown brain AND the system repo.
# Silent on success. Telegram only on failure.
#
# WHY systemd timer rather than Hermes cron:
#   This job must work when the agent is broken. If the model is down, the
#   container is wedged, or a bad config stops the gateway, Hermes cron stops
#   too — and that is exactly the night you most want your notes committed.
#   A systemd timer on the VM is outside the failure domain it protects.
#   Agent-authored jobs (news brief, calendar preview) DO belong in Hermes cron,
#   because those genuinely need the model. This one doesn't.
SCRIPT_NAME="nightly-git-backup"
source "$(dirname "$0")/lib.sh"

push_repo() {
  local repo="$1" name="$2"
  [ -d "$repo/.git" ] || { log "skip ${name}: not a git repo at ${repo}"; return 0; }
  cd "$repo"

  # Refuse to commit anything secret-shaped, even if .gitignore missed it.
  if git status --porcelain | grep -qE '\.env$|\.env\.|credentials\.json|token\.json|auth\.json|\.pem$|\.key$'; then
    die "${name}: refusing to commit — a secret-shaped file is staged or untracked. Inspect manually."
  fi

  if [ -z "$(git status --porcelain)" ]; then
    log "${name}: nothing to commit"
    return 0
  fi

  git add -A
  git commit -q -m "chore(${name}): nightly sync $(date -I)" || return 0
  local attempt=0
  until git push -u origin HEAD >/dev/null 2>&1; do
    attempt=$((attempt+1))
    [ "$attempt" -ge 4 ] && die "${name}: push failed after 4 attempts"
    sleep $((2 ** attempt))
  done
  log "${name}: pushed"
}

push_repo "$BRAIN_REPO"  "family-brain"
push_repo "$SYSTEM_REPO" "agent-system"
log "done"
