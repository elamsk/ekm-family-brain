#!/usr/bin/env bash
# ============================================================================
# Runs ON the target VM — Azure, a local VM, or bare metal. Called by
# provision-azure.sh for Azure, but safe and supported to run standalone.
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

# MUST match the uid/gid baked into deploy/Dockerfile (`useradd --uid 10001`).
# The container runs as this non-root user, and bind mounts keep host
# ownership — so anything it must read or write has to be owned by this id.
HERMES_UID="${HERMES_UID:-10001}"
HERMES_GID="${HERMES_GID:-10001}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ─── 1. Packages ────────────────────────────────────────────────────────────
# A freshly booted Ubuntu VM runs cloud-init and unattended-upgrades for
# the first several minutes, holding the dpkg/apt locks. Running apt-get
# straight after `az vm create` fails with "Could not get lock
# /var/lib/dpkg/lock-frontend" and, under `set -e`, kills this script at its
# very first step — leaving a VM with the repo copied and nothing installed.
# Wait the locks out instead of racing them.
# ─── 0. Which distro? ───────────────────────────────────────────────────────
# Supports Debian/Ubuntu (apt) and Fedora/RHEL (dnf). Everything after this
# point is distro-neutral.
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) PKG=apt  ;;
  *fedora*|*rhel*|*centos*) PKG=dnf ;;
  *) echo "  unrecognised distro '${ID:-?}' — assuming apt"; PKG=apt ;;
esac
echo "  distro: ${PRETTY_NAME:-$ID}  (package manager: $PKG)"

# SELinux is Enforcing by default on Fedora/RHEL. Bind mounts into containers
# are DENIED unless relabelled, which looks exactly like a uid permission bug:
# the container cannot read /data/.env and the gateway crash-loops. The compose
# file carries :z on every bind mount, which performs that relabel. Nothing to
# do here but say so, because the symptom is otherwise baffling.
if command -v getenforce >/dev/null 2>&1; then
  echo "  SELinux: $(getenforce) — compose mounts carry :z to relabel them"
fi

say "Waiting for cloud-init and any running package manager to finish"
sudo cloud-init status --wait >/dev/null 2>&1 || true
if [ "$PKG" = "dnf" ]; then
  # dnf serialises on its own transaction lock and retries internally, so the
  # apt-specific wait below does not apply.
  echo "  (dnf handles its own locking)"
fi

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
if [ "$PKG" = "apt" ]; then
  wait_for_apt || { echo "!! apt locked too long"; exit 1; }
  apt_install update -qq || { echo "!! apt-get update failed after 3 attempts"; exit 1; }
  apt_install install -y -qq \
    docker.io docker-compose-v2 git gnupg rclone zip unzip curl \
    || { echo "!! package install failed after 3 attempts"; exit 1; }
else
  # Fedora/RHEL. Docker CE from Docker's own repo rather than Fedora's
  # moby-engine: it ships the `docker compose` v2 plugin under the same name
  # and command used everywhere else here, so nothing downstream changes.
  # ffmpeg-free is the main-repo build (plain ffmpeg lives in RPM Fusion).
  if ! command -v docker >/dev/null 2>&1; then
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
      || sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
    sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin \
      || { echo "!! docker install failed"; exit 1; }
  fi
  sudo dnf -y install git gnupg2 rclone zip unzip curl ripgrep ffmpeg-free \
    || { echo "!! package install failed"; exit 1; }
fi
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true

# ─── 2. Swap — cloud Ubuntu images usually ship with none ──────────────────
# On a 1-2 GiB VM the docker build is the peak. Swap turns an OOM kill into
# slowness, which is the right trade on the smallest SKUs.
say "Swap (${SWAP_GB}G)"
if [ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -gt 0 ] && [ ! -f /swapfile ]; then
  echo "  swap already active ($(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')) — skipping"
  echo "  (Fedora enables zram swap by default; that is sufficient)"
elif [ -f /swapfile ]; then
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
# Prefer an explicit override, then the Azure LUN symlink, then any attached
# disk that has no partitions and is not the root disk. Keeps this script
# usable on a local VM (VirtualBox/Proxmox/Hyper-V) as well as Azure.
DEV="${DATA_DEV:-}"
if [ -z "$DEV" ] && [ -e /dev/disk/azure/scsi1/lun0 ]; then
  DEV=/dev/disk/azure/scsi1/lun0                      # Azure data disk
fi
if [ -z "$DEV" ]; then
  # Auto-detect a spare disk. This formats whatever it picks, so it is
  # deliberately conservative: it refuses to guess rather than risk mkfs on the
  # wrong device. An earlier version selected /dev/zram0 (a compressed RAM
  # disk) on a host where the root disk could not be resolved — the Hermes home
  # would have been wiped on every reboot.
  _root_src=$(findmnt -no SOURCE / 2>/dev/null)
  _root_disk=$(lsblk -no PKNAME "$_root_src" 2>/dev/null | head -1)
  if [ -z "$_root_disk" ]; then
    echo "  cannot determine the root disk — skipping auto-detection"
    echo "  (pass DATA_DEV=/dev/sdX explicitly if you have a separate data disk)"
  else
    while read -r _name _type _size; do
      [ "$_type" = "disk" ] || continue
      [ "$_name" = "$_root_disk" ] && continue
      # Virtual/removable block devices are never a data disk.
      case "$_name" in zram*|loop*|ram*|sr*|fd*|dm-*|md*) continue ;; esac
      # Must already carry no partitions...
      [ -n "$(lsblk -no NAME "/dev/$_name" | tail -n +2)" ] && continue
      # ...and be plausibly sized (guards against tiny pseudo-devices).
      [ "${_size:-0}" -lt 4294967296 ] && continue      # < 4 GiB
      DEV="/dev/$_name"; break
    done < <(lsblk -dbn -o NAME,TYPE,SIZE)
    [ -n "$DEV" ] && echo "  auto-detected spare disk: $DEV"
  fi
fi
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
  # Copy ONLY the brain: markdown the agent reads and writes as its memory.
  # Config, deploy manifests, scripts and docs belong to the system repo
  # (Phase 5). Copying them here creates a second copy that drifts from the
  # maintained one, and the agent would treat its own configuration as notes.
  for d in admin food places learning templates; do
    [ -d "$REPO/$d" ] && cp -r "$REPO/$d" "$HERMES_ROOT/workspace/family-brain/"
  done
  for f in news-preferences.md README.md readme.md .gitignore; do
    [ -f "$REPO/$f" ] && cp "$REPO/$f" "$HERMES_ROOT/workspace/family-brain/"
  done
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

# ─── 4b. Ownership for the bind mounts ──────────────────────────────────────
# The container runs as uid 10001 (non-root, by design). A bind mount carries
# the HOST's ownership through, so files created here as the admin user are
# unreadable to it. Without this the gateway crash-loops on startup with:
#   PermissionError: [Errno 13] Permission denied: '/data/.env'
# .env is mode 600, so even reading it fails.
say "Aligning ownership to the container user (uid ${HERMES_UID})"
sudo chown -R "${HERMES_UID}:${HERMES_GID}" "$HERMES_ROOT/data"
[ -d "$HERMES_ROOT/workspace/family-brain" ] && \
  sudo chown -R "${HERMES_UID}:${HERMES_GID}" "$HERMES_ROOT/workspace/family-brain"
sudo chmod 750 "$HERMES_ROOT/data"   # group = hermes, so the admin user can read config.yaml/SOUL.md
[ -f "$HERMES_ROOT/data/.env" ] && sudo chmod 600 "$HERMES_ROOT/data/.env"

# Let the admin user still read/edit the brain and read the config, without
# giving away the secrets file. Group membership needs a re-login to apply.
if ! getent group hermes >/dev/null 2>&1; then
  sudo groupadd -g "$HERMES_GID" hermes 2>/dev/null || true
fi
sudo usermod -aG "$HERMES_GID" "$USER" 2>/dev/null || true
# The brain repo is written by THREE identities: the container (uid 10001,
# the agent saving notes), the nightly backup service (root, via systemd), and
# the admin user editing by hand. Whoever writes first would otherwise leave
# files the others cannot modify, and git additionally refuses to touch a repo
# owned by someone else ("detected dubious ownership").
#
# Standard shared-repository setup: common group, group-writable, setgid on
# directories so new files inherit the group, and core.sharedRepository so git
# itself creates objects group-writable.
BRAIN="$HERMES_ROOT/workspace/family-brain"
if [ -d "$BRAIN" ]; then
  sudo chgrp -R "$HERMES_GID" "$BRAIN"
  sudo chmod -R g+rwX "$BRAIN"
  sudo find "$BRAIN" -type d -exec chmod g+s {} +     # new files inherit the group
  if [ -d "$BRAIN/.git" ]; then
    sudo -u "#${HERMES_UID}" git -C "$BRAIN" config core.sharedRepository group || true
  fi
  # git's ownership check is per-user, so every identity that touches the repo
  # needs the exemption. Without it the nightly backup dies on "dubious
  # ownership" at 03:15 with nobody watching.
  sudo git config --system --add safe.directory "$BRAIN" 2>/dev/null || true
  git config --global --add safe.directory "$BRAIN" 2>/dev/null || true
  echo "  ✓ brain repo shared between uid ${HERMES_UID}, root and $USER"
fi
echo "  ✓ /data and the brain are owned by ${HERMES_UID}; .env stays 0600"
echo "  NOTE: editing /opt/hermes/data/.env now needs sudo — it belongs to the"
echo "        container user, which is the point."

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
