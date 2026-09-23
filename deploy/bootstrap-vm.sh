#!/usr/bin/env bash
# ============================================================================
# Runs ON the Azure VM. Called by provision-azure.sh, but safe to run by hand.
# Covers DEPLOY-AZURE.md sections 2-6: packages, swap, data disk, repo layout,
# image build, systemd units.
#
# Idempotent — re-running is safe and skips work already done.
# Does NOT handle secrets. You fill .env yourself afterwards.
# ============================================================================
set -euo pipefail

SWAP_GB="${SWAP_GB:-2}"
HERMES_ROOT=/opt/hermes
REPO="$HERMES_ROOT/repo"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ─── 1. Packages ────────────────────────────────────────────────────────────
# A freshly booted Azure Ubuntu VM runs cloud-init and unattended-upgrades for
# the first several minutes, holding the dpkg/apt locks. Running apt-get
# straight after `az vm create` fails with "Could not get lock
# /var/lib/dpkg/lock-frontend" and, under `set -e`, kills this script at its
# very first step — leaving a VM with the repo copied and nothing installed.
# Wait the locks out instead of racing them.
say "Waiting for cloud-init and any running package manager to finish"
sudo cloud-init status --wait >/dev/null 2>&1 || true

wait_for_apt() {
  local waited=0 limit=600
  while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock \
                   /var/cache/apt/archives/lock >/dev/null 2>&1; do
    [ "$waited" -ge "$limit" ] && { echo "  apt still locked after ${limit}s"; return 1; }
    [ $((waited % 30)) -eq 0 ] && echo "  apt is locked, waiting… (${waited}s)"
    sleep 5; waited=$((waited + 5))
  done
  return 0
}
wait_for_apt || { echo "!! apt locked too long. Check: sudo fuser -v /var/lib/dpkg/lock-frontend"; exit 1; }
echo "  ✓ package manager free"

say "Installing packages"
# Retry: a lock can still be grabbed between the check above and the call.
apt_install() {
  local attempt
  for attempt in 1 2 3; do
    if sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"; then return 0; fi
    echo "  apt attempt ${attempt}/3 failed; waiting 20s"
    sleep 20; wait_for_apt || true
  done
  return 1
}
apt_install update -qq || { echo "!! apt-get update failed after 3 attempts"; exit 1; }
apt_install install -y -qq \
  docker.io docker-compose-v2 git gnupg rclone zip unzip curl \
  || { echo "!! package install failed after 3 attempts"; exit 1; }
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true

# ─── 2. Swap — Azure Ubuntu images ship with none ───────────────────────────
# On a 1-2 GiB VM the docker build is the peak. Swap turns an OOM kill into
# slowness, which is the right trade on the smallest SKUs.
say "Swap (${SWAP_GB}G)"
if [ -f /swapfile ]; then
  echo "  /swapfile exists — skipping"
else
  sudo fallocate -l "${SWAP_GB}G" /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024))
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo "  ✓ swap on"
fi
# Favour keeping the agent resident over swapping it out.
sudo sysctl -q vm.swappiness=10
grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf >/dev/null

# ─── 3. Data disk for the Hermes home ───────────────────────────────────────
# Use the stable Azure LUN path, not /dev/sdc — device letters can move
# across reboots and you do NOT want to mkfs the wrong disk.
say "Data disk"
DEV=/dev/disk/azure/scsi1/lun0
sudo mkdir -p "$HERMES_ROOT/data"
if ! [ -e "$DEV" ]; then
  echo "  WARNING: no data disk symlink at $DEV"
  echo "  Attached unpartitioned disks (the data disk should be among these):"
  lsblk -dn -o NAME,SIZE,TYPE | grep disk | sed 's/^/    /'
  echo "  Continuing on the OS disk. Hermes will work, but the home is not on"
  echo "  its own disk, so you cannot snapshot it separately. To fix: identify"
  echo "  the device above, then re-run with DATA_DEV=/dev/sdX set."
  DEV="${DATA_DEV:-}"
fi
if [ -z "$DEV" ] || ! [ -e "$DEV" ]; then
  echo "  (no separate data disk in use)"
elif mountpoint -q "$HERMES_ROOT/data"; then
  echo "  already mounted — skipping"
else
  if ! sudo blkid "$DEV" >/dev/null 2>&1; then
    echo "  formatting $DEV as ext4 (WAL-capable, unlike Azure Files)"
    sudo mkfs.ext4 -q -F "$DEV"
  else
    echo "  existing filesystem found — NOT reformatting"
  fi
  UUID=$(sudo blkid -s UUID -o value "$DEV")
  grep -q "$UUID" /etc/fstab || \
    echo "UUID=$UUID $HERMES_ROOT/data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo mount -a
  echo "  ✓ mounted at $HERMES_ROOT/data"
fi

# ─── 4. Directory layout ────────────────────────────────────────────────────
say "Layout"
sudo mkdir -p "$HERMES_ROOT"/{deploy,scripts,backups,workspace,data}
sudo chown -R "$USER" "$HERMES_ROOT"
chmod 700 "$HERMES_ROOT/backups"

cp -r "$REPO/deploy/." "$HERMES_ROOT/deploy/"
cp -r "$REPO/scripts/." "$HERMES_ROOT/scripts/"
# Belt and braces: systemd refuses a unit whose lines end in CR, and a cron
# script with a CRLF shebang fails the same way bootstrap did.
find "$HERMES_ROOT/deploy" "$HERMES_ROOT/scripts" -type f \
     \( -name '*.sh' -o -name '*.service' -o -name '*.timer' \
        -o -name '*.yml' -o -name '*.env' \) -exec sed -i 's/\r$//' {} +
chmod +x "$HERMES_ROOT"/scripts/*.sh

# The brain repo: the agent's working directory.
if [ ! -d "$HERMES_ROOT/workspace/family-brain/.git" ]; then
  mkdir -p "$HERMES_ROOT/workspace/family-brain"
  cp -r "$REPO/." "$HERMES_ROOT/workspace/family-brain/" 2>/dev/null || true
  rm -rf "$HERMES_ROOT/workspace/family-brain/deploy" \
         "$HERMES_ROOT/workspace/family-brain/scripts"
  ( cd "$HERMES_ROOT/workspace/family-brain" && git init -q 2>/dev/null || true )
  echo "  brain seeded (add your GitHub remote later — see below)"
fi

# Config + persona into the Hermes home.
for f in config.yaml SOUL.md; do
  if [ -f "$HERMES_ROOT/data/$f" ]; then
    echo "  $f already present — left alone (yours wins)"
  else
    cp "$REPO/agent-system/hermes/$f" "$HERMES_ROOT/data/$f"
  fi
done

# .env template — secrets stay empty, you fill them.
if [ ! -f "$HERMES_ROOT/data/.env" ]; then
  cp "$REPO/agent-system/hermes/env.example" "$HERMES_ROOT/data/.env"
  chmod 600 "$HERMES_ROOT/data/.env"
  echo "  .env template created (EMPTY — fill it before starting)"
fi

# ─── 5. Build the image ─────────────────────────────────────────────────────
say "Building the container image (slow on small SKUs — this is the RAM peak)"
cd "$HERMES_ROOT/deploy"
if sg docker -c "docker image inspect hermes-assistant:0.19.0" >/dev/null 2>&1; then
  echo "  image already built — skipping"
else
  sg docker -c "docker compose build" || {
    echo "!! build failed. On a 1 GiB VM this is usually the OOM killer."
    echo "   Check: dmesg | grep -i 'killed process'"
    echo "   Fix:   resize to Standard_B1ms, or raise SWAP_GB and re-run."
    exit 1
  }
fi

# ─── 6. systemd units ───────────────────────────────────────────────────────
say "Installing systemd units"
sudo cp "$HERMES_ROOT"/deploy/*.service "$HERMES_ROOT"/deploy/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
# Timers can start now. The gateway itself waits for .env to be filled.
sudo systemctl enable --now \
  hermes-backup-git.timer hermes-backup-encrypted.timer \
  hermes-disk-guard.timer hermes-health-check.timer
sudo systemctl enable hermes-assistant.service
echo "  ✓ timers active; hermes-assistant enabled (not started — needs .env)"

# ─── Summary ────────────────────────────────────────────────────────────────
cat <<EOF

────────────────────────────────────────────────────────────────────
VM bootstrap complete.

  free -h          -> $(free -h | awk '/^Mem:/{print $2" RAM"}'), $(free -h | awk '/^Swap:/{print $2" swap"}')
  df -h /opt/hermes/data | tail -1

NEXT, in order:

  1. nano /opt/hermes/data/.env          # GEMINI_API_KEY, TELEGRAM_BOT_TOKEN
  2. sudo systemctl start hermes-assistant.service
  3. docker exec hermes-gateway hermes doctor
  4. Message your bot on Telegram. Only user 701220126 is allowed.

  Git remote for the nightly backup (needs a fine-grained PAT):
     cd /opt/hermes/workspace/family-brain
     git remote add origin https://github.com/elamsk/ekm-family-brain.git

  NOTE: you must log out and back in for docker group membership to apply
  to your interactive shell.
────────────────────────────────────────────────────────────────────
EOF
