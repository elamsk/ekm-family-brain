#!/usr/bin/env bash
# ============================================================================
# One-command setup for the Hermes family chief-of-staff.
#
# Works on any Ubuntu 24.04 host: a local VM (VirtualBox / Hyper-V / Proxmox),
# bare metal, or a cloud VM. On Azure, provision-azure.sh creates the machine
# first and then calls this; everywhere else, this is the whole thing.
#
#   sudo ./setup.sh
#
# It runs the bootstrap (packages, swap, data disk, layout, image, systemd),
# then prompts for the secrets, writes them with the right ownership, and
# verifies the result end to end.
#
# Safe to re-run: every step skips work already done, and it never overwrites
# a secret you have already set.
# ============================================================================
set -euo pipefail

HERMES_ROOT=/opt/hermes
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_UID=10001

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0"
REAL_USER="${SUDO_USER:-root}"

# ─── 1. Bootstrap ───────────────────────────────────────────────────────────
say "Bootstrapping the host"
# Strip CR in case the repo came from a Windows checkout — a CRLF shebang
# makes every script unrunnable with a confusing "bash\r: not found".
find "$REPO" -type f \( -name '*.sh' -o -name '*.service' -o -name '*.timer' \
     -o -name '*.yml' -o -name '*.yaml' \) -exec sed -i 's/\r$//' {} +
chmod +x "$REPO"/deploy/*.sh "$REPO"/scripts/*.sh 2>/dev/null || true
sudo -u "$REAL_USER" true 2>/dev/null || true
"$REPO/deploy/bootstrap-vm.sh"

ENV_FILE="$HERMES_ROOT/data/.env"
CFG="$HERMES_ROOT/data/config.yaml"

# ─── 2. Secrets ─────────────────────────────────────────────────────────────
# Read into the file directly; never echoed, never in shell history.
set_secret() {
  local key="$1" prompt="$2" silent="${3:-yes}" cur val
  cur=$(grep -E "^${key}=.+" "$ENV_FILE" 2>/dev/null || true)
  if [ -n "$cur" ]; then ok "${key} already set — leaving it alone"; return 0; fi
  if [ "$silent" = "yes" ]; then read -r -s -p "  ${prompt}: " val; echo
  else read -r -p "  ${prompt}: " val; fi
  [ -n "$val" ] || { warn "${key} left empty — set it later in ${ENV_FILE}"; return 0; }
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
  ok "${key} written"
}

say "Secrets (input is hidden; nothing is echoed or logged)"
echo "  Gemini key: https://aistudio.google.com/apikey"
echo "  Bot token : message @BotFather on Telegram, /newbot"
echo "  Your ID   : message @userinfobot on Telegram (a number, not @username)"
echo
set_secret GEMINI_API_KEY        "Gemini API key"
set_secret TELEGRAM_BOT_TOKEN    "Telegram bot token"
set_secret TELEGRAM_ALLOWED_USERS "Your numeric Telegram user ID" no

chown "${HERMES_UID}:${HERMES_UID}" "$ENV_FILE"; chmod 600 "$ENV_FILE"

# ─── 3. Bind the allowlist into config.yaml ─────────────────────────────────
# allow_from MUST be a YAML list. As a bare string the adapter iterates it
# character by character and silently blocks its own owner.
TG_ID=$(grep -E '^TELEGRAM_ALLOWED_USERS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d ' ')
if [ -n "${TG_ID:-}" ] && [ -f "$CFG" ]; then
  if grep -qE '^\s+allow_from: *"?[0-9]' "$CFG"; then
    python3 - "$CFG" "$TG_ID" <<'PY'
import re,sys
p,uid=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'^(\s*)allow_from: *"?[0-9]+"?.*$', rf'\1allow_from:\n\1  - "{uid}"', s, flags=re.M)
open(p,'w').write(s)
PY
    chown "${HERMES_UID}:${HERMES_UID}" "$CFG"
    ok "telegram.allow_from set to a list containing ${TG_ID}"
  fi
fi

# ─── 4. Start ───────────────────────────────────────────────────────────────
say "Starting services"
systemctl start hermes-assistant.service
sleep 20
docker ps --format '  {{.Names}}\t{{.Status}}'

# ─── 5. Verify ──────────────────────────────────────────────────────────────
say "Verifying"
fails=0
if docker exec hermes-gateway hermes -z "Reply with just: OK" 2>&1 | grep -q .; then
  ok "primary model answered"
else warn "primary model did not answer"; fails=$((fails+1)); fi

if docker logs hermes-gateway 2>&1 | tail -40 | grep -q "No adapter available for telegram"; then
  warn "Telegram adapter not loaded — image may lack the 'messaging' extra"; fails=$((fails+1))
else ok "Telegram adapter loaded"; fi

systemctl is-enabled --quiet hermes-assistant.service \
  && ok "survives reboot (systemd unit enabled)" \
  || { warn "hermes-assistant.service is NOT enabled"; fails=$((fails+1)); }

echo
if [ "$fails" -eq 0 ]; then
  cat <<EOF
  Setup complete.

  NEXT, in Telegram:
    1. Message your bot — it should reply.
    2. Send /sethome so scheduled jobs have somewhere to deliver.

  STILL TO DO (each needs a credential or a browser):
    - git credential for the nightly brain backup
    - backup passphrase:
        sudo systemd-creds encrypt --name=backup-passphrase - /etc/hermes/backup.cred
    - Google read-only (Phase 3) — see docs/SHARED-ACCOUNT-HARDENING.md
EOF
else
  echo "  ${fails} check(s) failed — see docs/RESTORE.md for the symptoms."
  exit 1
fi
