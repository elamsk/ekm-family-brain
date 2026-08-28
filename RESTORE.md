# RESTORE.md — disaster recovery runbook

Written as the system was built, and meant to be followed by a tired person on
a bad day. Assume the Azure VM is gone.

## What exists, and where

| Layer | Location | Cadence | Restores |
|---|---|---|---|
| Markdown brain | GitHub `family-brain` (private) | nightly 03:15 | notes, recipes, places, records |
| System config | GitHub `agent-system` (private) | nightly 03:15 | config.yaml, SOUL.md, units, scripts |
| Secrets + state | Google Drive `Backups/hermes-home/*.zip.gpg` | Sunday 04:00 | .env, OAuth tokens, SQLite DBs, sessions, cron jobs |

**Git alone cannot restore a working agent.** It deliberately holds no
credentials. You need the encrypted archive for anything that logs in.

## What you need before you start

1. SSH access to a fresh Ubuntu VM.
2. The GitHub PAT (or the ability to make a new one).
3. **The backup passphrase.** It is stored nowhere on any machine — not in the
   repo, not in `.env`, not in the systemd unit. If it is lost, every
   `.zip.gpg` is permanently unreadable and you are rebuilding credentials from
   scratch: new Gemini key, re-run the Google OAuth flow, new BotFather token.
   Keep it in a password manager. This is the single point of failure and it is
   deliberate.

## Full restore

```bash
# 1. Base packages
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git gnupg rclone
sudo mkdir -p /opt/hermes/{data,backups,workspace} && sudo chown -R "$USER" /opt/hermes

# 2. The two repos
git clone git@github.com:<YOU>/agent-system.git  /opt/hermes/workspace/agent-system
git clone git@github.com:<YOU>/family-brain.git  /opt/hermes/workspace/family-brain
cp -r /opt/hermes/workspace/agent-system/deploy  /opt/hermes/deploy
cp -r /opt/hermes/workspace/agent-system/scripts /opt/hermes/scripts
chmod +x /opt/hermes/scripts/*.sh

# 3. The secrets and state — the part git does not have
rclone config          # re-authenticate as the AGENT's Google account
rclone copy agentdrive:Backups/hermes-home/ /opt/hermes/backups/ --max-age 30d
ls -t /opt/hermes/backups/*.zip.gpg | head -1     # newest archive

gpg --decrypt --output /tmp/hermes-home.zip /opt/hermes/backups/hermes-home-<STAMP>.zip.gpg
unzip -o /tmp/hermes-home.zip -d /opt/hermes/data
shred -u /tmp/hermes-home.zip
chmod 600 /opt/hermes/data/.env

# 4. Config (the repo copy is sanitized; the archive copy has your real values —
#    prefer the archive, and use the repo copy only to diff against)
diff /opt/hermes/workspace/agent-system/hermes/config.yaml /opt/hermes/data/config.yaml

# 5. Start
cd /opt/hermes/deploy && docker compose up -d
sudo cp /opt/hermes/deploy/*.service /opt/hermes/deploy/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-assistant.service
sudo systemctl enable --now hermes-backup-git.timer hermes-backup-encrypted.timer \
                            hermes-disk-guard.timer hermes-health-check.timer

# 6. Re-encrypt the backup passphrase for the new machine
#    (systemd credentials are bound to the host, so the old .cred will not work)
sudo systemd-creds encrypt --name=backup-passphrase - /etc/hermes/backup.cred

# 7. Verify
docker compose ps
docker exec hermes-gateway hermes doctor
docker exec hermes-gateway hermes cron list
```

Then send the bot a message. If it replies, you are back.

## Restoring a single file (the drill you should actually rehearse)

Do not wait for a disaster to find out the archive is unreadable.

```bash
ARCHIVE=$(ls -t /opt/hermes/backups/*.zip.gpg | head -1)
gpg --decrypt --output /tmp/probe.zip "$ARCHIVE"     # prompts for the passphrase
unzip -l /tmp/probe.zip | head -20                   # what is in there
unzip -p /tmp/probe.zip config.yaml > /tmp/restored-config.yaml
diff /tmp/restored-config.yaml /opt/hermes/data/config.yaml
shred -u /tmp/probe.zip /tmp/restored-config.yaml
```

If the `gpg --decrypt` step fails, your backups are worthless and you need to
know that today, not in an outage. Run this drill quarterly.

## Partial failures

**Gateway down, VM fine**
```bash
docker compose -f /opt/hermes/deploy/docker-compose.yml logs --tail 100 gateway
docker compose -f /opt/hermes/deploy/docker-compose.yml restart gateway
```

**Scheduled jobs stopped running**
```bash
docker exec hermes-gateway hermes cron status
docker exec hermes-gateway hermes cron runs --limit 20
systemctl list-timers 'hermes-*'
```

**Disk full** — the disk guard should have warned. Manually:
```bash
/opt/hermes/scripts/disk-guard.sh
docker system prune -f
```

**Brain repo has a conflict** (hand-edited on GitHub and locally):
```bash
cd /opt/hermes/workspace/family-brain
git pull --no-rebase        # merge, resolve by hand, keep both sides
```
The nightly job refuses to force anything, so a conflict stalls the sync
rather than losing a note. Fix it by hand.
