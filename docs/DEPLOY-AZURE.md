# Deploying to Azure

## The one-command path

```bash
cd deploy
./provision-azure.sh --dry-run     # read the plan first — touches nothing
./provision-azure.sh               # create everything
```

It creates the resource group, VM, and data disk; verifies every resource is
in India; ships this repo to the VM; and runs `bootstrap-vm.sh` there, which
handles packages, swap, disk mount, image build, and systemd units. Idempotent
— re-running skips what already exists. `--skip-create` re-runs just the
bootstrap against an existing VM.

It deliberately stops short of anything needing a secret or a browser: you
fill `.env`, set the backup passphrase, and do the Google OAuth yourself. The
script prints that checklist when it finishes.

**Neither script has been run against a live Azure subscription.** The logic
was tested offline against a stubbed `az` (region guard, SKU check, idempotency
skips, dry-run output), and both pass `shellcheck -S warning`. Use `--dry-run`
first and read what it intends to do — every step is a plain `az` command you
could run by hand.

The sections below are that same process, manually, if you prefer it.


Nothing here has been run against a live Azure subscription — it is written
from the verified local artifacts and needs a real host to prove out. Steps
that cost money or create accounts are marked **[you]** and are yours to run.

## 0. Region — everything lives in India

Every Azure resource in this deployment is pinned to an Indian region. The
region is a single variable so it is set once and inherited by the resource
group, the VM, both disks, and the public IP.

```bash
export AZ_REGION=centralindia      # Pune
```

### Sizing — minimum-cost defaults

Configured for the smallest practical footprint. Everything is an env var, so
you can size up later without editing anything:

| Setting | Default | Why |
|---|---|---|
| `VM_SIZE` | `Standard_B1ms` (1 vCPU, 2 GiB) | smallest that reliably builds and runs the image |
| `OS_DISK_SKU` | `Standard_LRS` (HDD) | cheapest; the OS disk is not latency-sensitive |
| `DATA_DISK_SKU` | `StandardSSD_LRS` | SQLite lives here — worth the small premium |
| `DATA_DISK_GB` | `16` | markdown, config and state are tiny; backups prune |
| `SWAP_GB` | `2` | Azure Ubuntu ships with none; turns an OOM kill into slowness |

**On `Standard_B1s` (1 GiB).** It is the cheapest burstable size, and the
script will use it if you ask, but the docker build is the memory peak and on
1 GiB it will most likely be OOM-killed. The swapfile helps and it may
complete, slowly. `B1ms` is the realistic floor. If a build dies, check
`dmesg | grep -i 'killed process'` before suspecting anything else.

The model runs in Google's cloud, so CPU here is mostly idle — RAM during the
build is the binding constraint, not steady-state compute.

**Costs change and vary by region, so this repo does not quote prices.** Check
the current figures for your subscription before committing:

```bash
az vm list-skus --location "$AZ_REGION" --resource-type virtualMachines \
  --query "[?name=='Standard_B1ms']" -o table
```

Then the Azure Pricing Calculator for the VM, both disks, and the public IP.
The public IP and disks are billed whether or not the VM is running — so
`az vm deallocate` reduces cost but does not eliminate it. To stop charges
entirely, delete the resource group (the script prints that command).

**Why `centralindia`:** of the Azure regions inside India it has the broadest
VM SKU coverage and supports availability zones, which the others do not
consistently. The alternatives, if you have a reason to prefer one:

| Region | Location | Notes |
|---|---|---|
| `centralindia` | Pune | **default** — widest SKU coverage, availability zones |
| `southindia` | Chennai | narrower SKU set, no availability zones |
| `westindia` | Mumbai | narrowest SKU set; B-series not always offered |
| `jioindiawest` | Jamnagar | Jio-operated; restricted service catalogue |
| `jioindiacentral` | Nagpur | Jio-operated; restricted service catalogue |

Confirm the size you want actually exists in your chosen region before
provisioning, rather than discovering it on the `az vm create`:

```bash
az vm list-skus --location "$AZ_REGION" --size Standard_B2 --output table
```

If `Standard_B2s` is not offered, `Standard_B2ms` (2 vCPU / 8 GB) is the next
step up and is widely available. Either is ample — the model runs in Google's
cloud, not on this box.

### What "hosted in India" does and does not cover

This pins the **Azure** resources — compute, disks, public IP, and therefore
the Hermes home, the SQLite state, and the encrypted backups while they sit on
the VM. That part is genuinely in India.

It does **not** make the whole system India-resident, and it would be wrong to
assume otherwise:

- **Model inference** goes to Google's Gemini API. Google decides where that
  is served, and it is not bound by your Azure region.
- **Gmail, Google Calendar, and Google Drive** — including the weekly
  encrypted backup archives — are stored wherever Google places that account's
  data, which you do not control from Azure.
- **Telegram** relays every message through its own infrastructure.
- **GitHub** holds the markdown brain and the system config.

So household documents and conversation content still leave India by design in
this architecture. If the goal is a compliance requirement — DPDP Act or
similar — hosting the VM in India is necessary but **not sufficient**, and the
above four are the gaps to close. Tell me if that is the driver and I will
rework the design: Azure OpenAI in `centralindia` for inference, Azure Blob
Storage in-region instead of Drive for backups, and Microsoft Graph in place of
Gmail. That is a materially different build, which is why I have not assumed it.

The encrypted weekly archive is the one piece where this is least bad: it is
AES-256 encrypted before it ever leaves the VM, so Drive holds ciphertext only.

## 1. Provision the VM  **[you — this costs money]**

```bash
export AZ_REGION=centralindia

az group create -n hermes-rg -l "$AZ_REGION"

az vm create -g hermes-rg -n hermes-vm \
  --location "$AZ_REGION" \
  --image Ubuntu2404 --size Standard_B2s \
  --admin-username azureuser --generate-ssh-keys \
  --public-ip-sku Standard --storage-sku StandardSSD_LRS

# Data disk for the Hermes home, so it can be snapshotted separately
az vm disk attach -g hermes-rg --vm-name hermes-vm --name hermes-data \
  --new --size-gb 32 --sku StandardSSD_LRS
```

The disk inherits the VM's region, and the resource group's location sets the
default for anything added later — but inheritance is a convention, not a
guarantee, so verify it below rather than trusting it.

**Network security group: open port 22 only.** Do not open 9119. The web UI is
reached through an SSH tunnel — see ARCHITECTURE.md.

### Verify every resource actually landed in India

Run this after provisioning, and again after adding any resource later. It
fails loudly if anything is outside India:

```bash
az resource list -g hermes-rg --query "[].{name:name, type:type, location:location}" -o table

# Hard check — plain shell rather than a clever JMESPath query, so you can
# read what it does. Lists any offender and exits 1.
offenders=$(az resource list -g hermes-rg --query "[].{n:name,loc:location}" -o tsv \
  | grep -vE '(centralindia|southindia|westindia|jioindiawest|jioindiacentral)$')

if [ -n "$offenders" ]; then
  echo "!! RESOURCES OUTSIDE INDIA:"; echo "$offenders"; exit 1
else
  echo "OK: every resource in hermes-rg is in an Indian region"
fi
```

Check the storage location of the VM's disks too — they are separate resources
and a snapshot or restore can land one elsewhere:

```bash
az disk list -g hermes-rg --query "[].{name:name, location:location}" -o table
```

To stop a stray resource being created elsewhere in future, pin the default:

```bash
az configure --defaults location=centralindia group=hermes-rg
```

## 2. Prepare the host

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 git gnupg rclone
sudo usermod -aG docker "$USER" && newgrp docker

# Mount the data disk at /opt/hermes/data (adjust device as lsblk reports)
sudo mkfs.ext4 /dev/sdc
sudo mkdir -p /opt/hermes/data
echo "/dev/sdc /opt/hermes/data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
sudo mkdir -p /opt/hermes/{deploy,scripts,backups,workspace}
sudo chown -R "$USER" /opt/hermes
```

ext4 on a managed disk, not Azure Files — see ARCHITECTURE.md for why this
matters to SQLite.

## 3. Lay down the repos

```bash
git clone git@github.com:<YOU>/agent-system.git  /opt/hermes/workspace/agent-system
git clone git@github.com:<YOU>/family-brain.git  /opt/hermes/workspace/family-brain
cp -r /opt/hermes/workspace/agent-system/deploy/*  /opt/hermes/deploy/
cp -r /opt/hermes/workspace/agent-system/scripts/* /opt/hermes/scripts/
chmod +x /opt/hermes/scripts/*.sh
cp /opt/hermes/workspace/agent-system/hermes/config.yaml /opt/hermes/data/config.yaml
cp /opt/hermes/workspace/agent-system/hermes/SOUL.md     /opt/hermes/data/SOUL.md
```

Then replace every `<PLACEHOLDER>` in `config.yaml`, `SOUL.md`, and
`deploy/compose.env`:

```bash
grep -rn '<[A-Z_0-9]*>' /opt/hermes/data /opt/hermes/deploy
```

## 4. Secrets  **[you]**

```bash
cp /opt/hermes/workspace/agent-system/hermes/env.example /opt/hermes/data/.env
chmod 600 /opt/hermes/data/.env
$EDITOR /opt/hermes/data/.env
```

## 5. Build and start

```bash
cd /opt/hermes/deploy
docker compose build          # ~3 min
docker compose up -d
docker compose ps
docker exec hermes-gateway hermes doctor
```

## 6. Make it survive reboots

```bash
sudo cp /opt/hermes/deploy/*.service /opt/hermes/deploy/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-assistant.service
sudo systemctl enable --now hermes-backup-git.timer hermes-backup-encrypted.timer \
                            hermes-disk-guard.timer hermes-health-check.timer
systemctl list-timers 'hermes-*'
sudo reboot        # then confirm everything came back on its own
```

These are **system** units, not `--user` units: they start at boot with nobody
logged in, so there is no lingering to enable and nothing to forget.

## 7. Backup passphrase  **[you]**

```bash
sudo mkdir -p /etc/hermes
sudo systemd-creds encrypt --name=backup-passphrase - /etc/hermes/backup.cred
# type the passphrase, then Ctrl-D. It is host-bound and root-only.
```

Keep the passphrase in your password manager. It exists nowhere else — see
RESTORE.md.

## 8. rclone to the agent's Drive  **[you]**

```bash
rclone config     # name: agentdrive, type: drive, sign in as the AGENT account
rclone mkdir agentdrive:Backups/hermes-home
rclone lsd agentdrive:
```

## 9. Verify before trusting it

```bash
/opt/hermes/scripts/health-check.sh          # should print "all checks passed"
sudo systemctl start hermes-backup-git.service && journalctl -u hermes-backup-git -n 20
sudo systemctl start hermes-backup-encrypted.service
ls -la /opt/hermes/backups/                  # a .zip.gpg should exist
```

Then run the single-file restore drill in RESTORE.md. An encrypted backup
nobody has ever opened is not a backup.
