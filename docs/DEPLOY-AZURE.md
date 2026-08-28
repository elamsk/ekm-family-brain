# Deploying to Azure

Nothing here has been run against a live Azure subscription — it is written
from the verified local artifacts and needs a real host to prove out. Steps
that cost money or create accounts are marked **[you]** and are yours to run.

## 1. Provision the VM  **[you — this costs money]**

```bash
az group create -n hermes-rg -l westeurope
az vm create -g hermes-rg -n hermes-vm \
  --image Ubuntu2404 --size Standard_B2s \
  --admin-username azureuser --generate-ssh-keys \
  --public-ip-sku Standard --storage-sku StandardSSD_LRS
# Data disk for the Hermes home, so it can be snapshotted separately
az vm disk attach -g hermes-rg --vm-name hermes-vm --name hermes-data \
  --new --size-gb 32 --sku StandardSSD_LRS
```

**Network security group: open port 22 only.** Do not open 9119. The web UI is
reached through an SSH tunnel — see ARCHITECTURE.md.

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
