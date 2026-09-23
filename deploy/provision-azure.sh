#!/usr/bin/env bash
# ============================================================================
# One-command Azure provisioning for the Hermes family chief-of-staff.
# Runs on YOUR machine (needs: az CLI, ssh, tar). Creates the VM, then runs
# bootstrap-vm.sh on it over SSH.
#
#   ./provision-azure.sh                 # create everything
#   ./provision-azure.sh --dry-run       # print what it would do, touch nothing
#   ./provision-azure.sh --skip-create   # VM exists; just re-run the bootstrap
#
# Idempotent: re-running skips resources that already exist.
#
# NOT YET RUN AGAINST A LIVE SUBSCRIPTION. Use --dry-run first and read the
# plan. Every step is a plain `az` command you can run by hand.
# ============================================================================
set -euo pipefail

# ─── Settings — all minimum-cost defaults. Override by exporting first. ─────
AZ_REGION="${AZ_REGION:-centralindia}"          # India, per requirement
RG="${RG:-hermes-rg}"
VM_NAME="${VM_NAME:-hermes-vm}"
ADMIN_USER="${ADMIN_USER:-azureuser}"

# Smallest size that actually works. See the table in DEPLOY-AZURE.md §0.
# B1s (1 GiB) is cheaper but OOMs building the image — B1ms + swap is the
# realistic floor. Export VM_SIZE=Standard_B1s to try it anyway.
VM_SIZE="${VM_SIZE:-Standard_B1ms}"

OS_DISK_SKU="${OS_DISK_SKU:-Standard_LRS}"      # HDD — cheapest, fine for the OS
DATA_DISK_SKU="${DATA_DISK_SKU:-StandardSSD_LRS}"  # SSD — SQLite lives here
DATA_DISK_GB="${DATA_DISK_GB:-16}"
IMAGE="${IMAGE:-Ubuntu2404}"
SWAP_GB="${SWAP_GB:-2}"

DRY_RUN=0; SKIP_CREATE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --skip-create) SKIP_CREATE=1 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

# ─── Preflight ──────────────────────────────────────────────────────────────
say "Preflight"
command -v az  >/dev/null || die "az CLI not found: https://aka.ms/InstallAzureCLI"
command -v ssh >/dev/null || die "ssh not found"
az account show >/dev/null 2>&1 || die "not logged in — run: az login"

SUB=$(az account show --query name -o tsv)
echo "  subscription : $SUB"
echo "  region       : $AZ_REGION"
echo "  vm           : $VM_NAME ($VM_SIZE)"
echo "  os disk      : $OS_DISK_SKU"
echo "  data disk    : ${DATA_DISK_GB}GB $DATA_DISK_SKU"

case "$AZ_REGION" in
  centralindia|southindia|westindia|jioindiawest|jioindiacentral) ;;
  *) die "AZ_REGION '$AZ_REGION' is not an Indian region. All resources must stay in India." ;;
esac

# Confirm the size actually exists here BEFORE creating anything.
say "Checking $VM_SIZE is available in $AZ_REGION"
if [ "$DRY_RUN" = 0 ]; then
  # Query by name directly. (An earlier version passed --size with the full
  # SKU name, which is a family prefix filter and matched nothing.)
  if ! az vm list-skus --location "$AZ_REGION" --resource-type virtualMachines \
        --query "[?name=='$VM_SIZE'].name" -o tsv 2>/dev/null | grep -q .; then
    echo "  WARNING: could not confirm $VM_SIZE in $AZ_REGION."
    echo "  Check with: az vm list-skus --location $AZ_REGION --output table | grep B1"
    read -r -p "  Continue anyway? [y/N] " yn
    [ "$yn" = "y" ] || exit 1
  else
    echo "  ✓ $VM_SIZE available"
  fi
fi

if [ "$VM_SIZE" = "Standard_B1s" ]; then
  echo
  echo "  NOTE: B1s has 1 GiB RAM. The docker build will likely be OOM-killed."
  echo "  A ${SWAP_GB}GB swapfile is created to help, but expect it to be slow."
fi

# ─── 1. Resource group + VM ─────────────────────────────────────────────────
if [ "$SKIP_CREATE" = 0 ]; then
  say "Resource group"
  if az group show -n "$RG" >/dev/null 2>&1; then
    echo "  already exists — skipping"
  else
    run az group create -n "$RG" -l "$AZ_REGION" --output none
  fi

  say "VM"
  if az vm show -g "$RG" -n "$VM_NAME" >/dev/null 2>&1; then
    echo "  already exists — skipping"
  else
    run az vm create -g "$RG" -n "$VM_NAME" \
      --location "$AZ_REGION" \
      --image "$IMAGE" --size "$VM_SIZE" \
      --admin-username "$ADMIN_USER" --generate-ssh-keys \
      --os-disk-size-gb 30 --storage-sku "$OS_DISK_SKU" \
      --public-ip-sku Standard \
      --nsg-rule SSH \
      --output none
  fi

  say "Data disk (Hermes home — ext4, so SQLite WAL works)"
  if az disk show -g "$RG" -n hermes-data >/dev/null 2>&1; then
    echo "  already exists — skipping"
  else
    run az vm disk attach -g "$RG" --vm-name "$VM_NAME" --name hermes-data \
      --new --size-gb "$DATA_DISK_GB" --sku "$DATA_DISK_SKU" --output none
  fi
fi

# ─── 2. Verify everything landed in India ───────────────────────────────────
say "Verifying all resources are in an Indian region"
if [ "$DRY_RUN" = 0 ]; then
  offenders=$(az resource list -g "$RG" --query "[].{n:name,loc:location}" -o tsv \
    | grep -vE '(centralindia|southindia|westindia|jioindiawest|jioindiacentral)$' || true)
  if [ -n "$offenders" ]; then
    echo "!! RESOURCES OUTSIDE INDIA:"; echo "$offenders"; exit 1
  fi
  echo "  ✓ every resource in $RG is in an Indian region"
fi

# ─── 3. Ship the repo and bootstrap the VM ──────────────────────────────────
say "Getting the VM's address"
if [ "$DRY_RUN" = 1 ]; then
  IP="<vm-ip>"
else
  IP=$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)
  [ -n "$IP" ] || die "could not determine the VM's public IP"
fi
echo "  $IP"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
say "Copying the repo to the VM"
# Ship the working tree rather than cloning: avoids putting a GitHub token on
# the VM at provisioning time. Git remotes are configured later, by you.
if [ "$DRY_RUN" = 0 ]; then
  tar czf /tmp/hermes-repo.tgz -C "$REPO_ROOT" --exclude='.git' .
  for i in 1 2 3 4 5; do
    ssh -o StrictHostKeyChecking=accept-new "$ADMIN_USER@$IP" true 2>/dev/null && break
    echo "  waiting for sshd ($i/5)…"; sleep $((i * 5))
  done
  scp -q /tmp/hermes-repo.tgz "$ADMIN_USER@$IP:/tmp/"
  rm -f /tmp/hermes-repo.tgz
else
  echo "  [dry-run] tar + scp repo to $ADMIN_USER@$IP"
fi

say "Running bootstrap-vm.sh on the VM"
if [ "$DRY_RUN" = 0 ]; then
  # No -t: forcing a pty while stdin is a heredoc can swallow the remote
  # script's output, which is how a failed bootstrap looked like a clean run.
  # shellcheck disable=SC2029  # we want SWAP_GB expanded locally
  ssh "$ADMIN_USER@$IP" "SWAP_GB=$SWAP_GB bash -s" <<'REMOTE'
set -euo pipefail
sudo mkdir -p /opt/hermes
sudo chown -R "$USER" /opt/hermes
mkdir -p /opt/hermes/repo
tar xzf /tmp/hermes-repo.tgz -C /opt/hermes/repo
rm -f /tmp/hermes-repo.tgz
chmod +x /opt/hermes/repo/deploy/bootstrap-vm.sh
SWAP_GB="${SWAP_GB:-2}" /opt/hermes/repo/deploy/bootstrap-vm.sh
REMOTE
else
  echo "  [dry-run] ssh $ADMIN_USER@$IP -> bootstrap-vm.sh"
fi

# ─── Done ───────────────────────────────────────────────────────────────────
cat <<EOF

────────────────────────────────────────────────────────────────────
Provisioning complete.

  ssh $ADMIN_USER@$IP

STILL TO DO BY HAND (each needs a secret or a browser):

 1. Secrets:      ssh in, then: nano /opt/hermes/data/.env
                  Fill GEMINI_API_KEY and TELEGRAM_BOT_TOKEN at minimum.
                  Then: cd /opt/hermes/deploy && docker compose up -d

 2. Backup passphrase:
                  sudo systemd-creds encrypt --name=backup-passphrase - \\
                    /etc/hermes/backup.cred

 3. Google OAuth + rclone (Phase 3/6) — see docs/DEPLOY-AZURE.md §8.
                  Keep mail READ-ONLY: docs/SHARED-ACCOUNT-HARDENING.md

 4. Web UI (never exposed publicly):
                  ssh -L 9119:127.0.0.1:9119 $ADMIN_USER@$IP

To tear the whole thing down:
                  az group delete -n $RG --yes --no-wait
────────────────────────────────────────────────────────────────────
EOF
