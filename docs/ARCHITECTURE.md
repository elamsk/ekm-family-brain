# Architecture and the decisions behind it

Every choice here favours the inspectable option. Where I picked something
non-obvious, the reasoning is recorded so it can be argued with later.

## Host: Azure VM running Docker, not Azure Container Apps

You said "Azure as docker or container app". I chose a **Linux VM running
Docker Compose**, supervised by systemd. Three reasons, all of which would
bite a Container Apps deployment specifically:

**1. Scale-to-zero breaks scheduled jobs.** Container Apps scales to zero
replicas by default. The daily news brief, the weekly calendar preview, and
the health check all rely on a scheduler being alive at a specific wall-clock
minute. A scaled-to-zero replica has no scheduler. Pinning `minReplicas=1`
fixes it — and removes the cost argument for Container Apps in the first
place, because you are then paying for an always-running container either way.

**2. Persistent storage would have to be Azure Files, and that corrupts the
concurrency model.** Hermes keeps roughly a dozen SQLite databases in its home
directory (`state.db`, `memory_store.db`, `executions.db`, `kanban.db`,
`crypto.db`, and more) and opens them in WAL mode. WAL requires shared-memory
coordination and `fcntl` byte-range locks that do not work over SMB/CIFS.
Hermes handles this gracefully — `hermes_state.py` detects the failure and
falls back to `journal_mode=DELETE` — but its own comment spells out the cost:

> *"Concurrency drops — concurrent readers are blocked during a write."*

With a gateway, a web UI, and a cron scheduler all sharing those databases,
that is a recipe for lock contention and stalled jobs. A VM's managed disk is
ext4, where WAL works properly. This is the single strongest argument for the
VM shape.

**3. Debuggability.** When the agent misbehaves at 3am you want `ssh`, `docker
logs`, and a shell in the container. Container Apps gives you a console with
more friction and less state.

**Sizing:** a `Standard_B2s` (2 vCPU, 4 GB) is enough — the model runs in
Google's cloud, not here. Put the Hermes home on a separate managed disk so
you can snapshot it independently of the OS disk.

**If you overrule me and want Container Apps anyway:** set `minReplicas: 1`,
mount Azure Files for `/data`, and accept the DELETE-journal concurrency hit.
It will work. It will just be slower and harder to debug for no saving.

## Why no local Ollama fallback

Phase 1.4 asked for a local GPU fallback. A GPU-equipped Azure VM (NC/NV
series) costs roughly an order of magnitude more per month than the B2s that
runs this workload, in order to insure against Gemini being down. That trade
is poor. The fallback chain is instead a **second cloud tier**:
`gemini-2.5-flash` → `gemini-2.0-flash`.

Note honestly what this does and does not buy you: it covers a model-level
failure (a specific model deprecated, overloaded, or rate-limited), which is
the common case. It does **not** cover a Google-wide outage or an expired API
key, because both models sit behind the same credential and the same provider.

If you want genuine provider independence, add a second entry to
`fallback_providers` pointing at a different vendor with a different key. That
is a real second leg. Say the word and I will wire it up.

## Services

| Service | Command | Exposure |
|---|---|---|
| `hermes-gateway` | `hermes gateway run` | none — outbound only |
| `hermes-webui` | `hermes serve --port 9119` | `127.0.0.1` only |

The gateway is the always-on process: it holds the Telegram connection and
runs the cron scheduler. `hermes gateway run` is the foreground mode Hermes
documents for containers.

**The web UI is never published to the internet.** It fronts an agent with
mail, calendar, drive, and shell access. Reach it through an SSH tunnel:

```bash
ssh -L 9119:127.0.0.1:9119 <azure-vm>
# then open http://127.0.0.1:9119
```

Hermes hardened this itself in June 2026 — a non-loopback bind now requires an
auth provider regardless of flags — but the tunnel is the belt to that
suspenders. Do not open port 9119 in the Azure network security group.

## Scheduling: two different mechanisms, on purpose

**Hermes cron** runs the jobs that need the model: the daily news brief, the
weekly calendar preview, memory curation. These are prompts, and they belong
where the agent can see them.

**systemd timers** run the jobs that must work *when the agent is broken*: the
nightly git backup, the weekly encrypted backup, the disk guard, the health
check. If a bad config wedges the gateway, Hermes cron dies with it — and that
is precisely the night you most want your notes committed and an alert sent.
Putting those four outside the agent's failure domain is the whole point.

`hermes send` makes this work: it delivers to Telegram using the gateway's
stored bot token, with no LLM and no running gateway required. A failure
notifier that depends on the failing component is not a notifier.

## The two-repo split

| Repo | Holds | Backup |
|---|---|---|
| `family-brain` | markdown: preferences, recipes, places, records | git push, nightly |
| `agent-system` | config, SOUL.md, units, scripts | git push, nightly |
| *(neither)* | `.env`, OAuth tokens, SQLite state, sessions | encrypted zip → Drive, weekly |

The third row is the one people forget. Git holds nothing secret, so git alone
cannot restore a working agent — only the encrypted weekly archive can. See
`RESTORE.md`.
