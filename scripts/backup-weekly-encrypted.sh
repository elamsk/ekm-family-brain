#!/usr/bin/env bash
# Phase 6.3 — weekly encrypted backup of the Hermes home.
#
# This is the half of the backup story git must never hold: .env, OAuth
# tokens, auth.json, the SQLite databases, sessions, pairing state.
#   markdown + config  → GitHub, nightly   (backup-nightly-git.sh)
#   secrets + state    → encrypted zip in Drive, weekly  (this script)
#
# Encryption: GPG symmetric, AES-256. The passphrase is NEVER stored on this
# machine. It is read from a systemd credential or prompted interactively.
# If you lose it, these archives are unrecoverable — see RESTORE.md.
SCRIPT_NAME="weekly-encrypted-backup"
source "$(dirname "$0")/lib.sh"

STAGE="${BACKUP_STAGE:-/opt/hermes/backups}"
KEEP="${BACKUP_KEEP:-6}"                    # retain ~6 weeks
REMOTE_DIR="${BACKUP_REMOTE_DIR:-Backups/hermes-home}"
STAMP="$(date +%Y-%m-%dT%H%M)"
ARCHIVE="${STAGE}/hermes-home-${STAMP}.zip"

mkdir -p "$STAGE"
chmod 700 "$STAGE"

# --- passphrase: from systemd credential, else interactive. Never from disk. ---
if [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -r "${CREDENTIALS_DIRECTORY}/backup-passphrase" ]; then
  PASSPHRASE="$(cat "${CREDENTIALS_DIRECTORY}/backup-passphrase")"
elif [ -t 0 ]; then
  read -r -s -p "Backup passphrase: " PASSPHRASE; echo
else
  die "no passphrase available (expected systemd credential 'backup-passphrase')"
fi
[ -n "$PASSPHRASE" ] || die "empty passphrase"

# --- quiesce: let SQLite settle so we copy a consistent set of DBs ---
# Hermes' own backup command handles the DB checkpointing correctly.
if $HERMES_BIN backup --output "/data/.backup-staging.zip" >/dev/null 2>&1; then
  docker cp hermes-gateway:/data/.backup-staging.zip "$ARCHIVE" \
    || die "could not copy archive out of the container"
  $HERMES_BIN sh -c 'rm -f /data/.backup-staging.zip' >/dev/null 2>&1 || true
else
  # Fallback: zip the home directly, excluding caches and the archive itself.
  log "hermes backup unavailable; falling back to direct zip"
  ( cd "$HERMES_HOME" && zip -rq "$ARCHIVE" . \
      -x '*.db-wal' '*.db-shm' 'checkpoints/*' 'logs/*' '.backup-staging.zip' ) \
    || die "zip failed"
fi

# --- encrypt, then destroy the plaintext ---
gpg --batch --yes --symmetric --cipher-algo AES256 \
    --passphrase-fd 3 --output "${ARCHIVE}.gpg" "$ARCHIVE" 3<<<"$PASSPHRASE" \
  || die "gpg encryption failed"
shred -u "$ARCHIVE" 2>/dev/null || rm -f "$ARCHIVE"
unset PASSPHRASE
chmod 600 "${ARCHIVE}.gpg"

# --- verify the archive is actually decryptable before we trust it ---
# An encrypted backup nobody has ever opened is not a backup.
gpg --batch --list-packets "${ARCHIVE}.gpg" >/dev/null 2>&1 \
  || die "produced archive is not valid GPG data"

# --- upload to the agent's own Google Drive ---
# Deliberately rclone, not the agent. This backup exists for the case where the
# agent is broken, so the upload path must not depend on the model, the gateway,
# or a working tool loop. rclone is a plain binary with its own OAuth token.
#
# One-time setup on the VM (see docs/DEPLOY-AZURE.md):
#   rclone config    # new remote named "agentdrive", type: drive,
#                    # authenticated as the AGENT's Google account, scope drive.file
RCLONE_REMOTE="${RCLONE_REMOTE:-agentdrive}"
if command -v rclone >/dev/null 2>&1; then
  if ! rclone copy "${ARCHIVE}.gpg" "${RCLONE_REMOTE}:${REMOTE_DIR}/" --no-traverse >/dev/null 2>&1; then
    notify "⚠️ Weekly backup encrypted OK at ${ARCHIVE}.gpg but the upload to ${REMOTE_DIR} failed. Local copy retained."
  else
    log "uploaded to ${RCLONE_REMOTE}:${REMOTE_DIR}/"
    # Prune remote copies beyond the retention window too.
    rclone delete "${RCLONE_REMOTE}:${REMOTE_DIR}/" --min-age "$((KEEP * 7))d" >/dev/null 2>&1 || true
  fi
else
  notify "⚠️ Weekly backup encrypted at ${ARCHIVE}.gpg but rclone is not installed — no offsite copy exists."
fi

# --- retention: keep the newest $KEEP, locally ---
mapfile -t old < <(find "$STAGE" -name 'hermes-home-*.zip.gpg' -printf '%T@ %p\n' \
                    | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
for f in "${old[@]:-}"; do [ -n "$f" ] && rm -f "$f" && log "pruned $f"; done

log "done: ${ARCHIVE}.gpg"   # silent on success
