# family-brain

The long-term memory of our household chief-of-staff agent, plus the
configuration that runs it. Plain markdown, one topic per file, so it stays
readable and fixable without the agent.

## Layout

```
admin/       household records, subscriptions, renewals, warranties
food/        recipes, restaurants, dietary preferences
places/      travel, day trips, venues
learning/    things we're studying
templates/   scaffolds for the above
news-preferences.md   what the daily brief should cover  ← fill this in

agent-system/   ← config + persona. Split into its own private repo.
  hermes/config.yaml   pinned models, safety layers (no secrets)
  hermes/SOUL.md       persona and house rules
  hermes/env.example   secret names only, never values
deploy/      Dockerfile, compose, systemd units for the Azure VM
scripts/     backup, disk guard, health check
docs/        architecture decisions, Azure deploy, model-change checklist
RESTORE.md   disaster recovery runbook
```

> **Note on the two-repo split.** Your plan calls for `family-brain` and
> `agent-system` as separate private repos. Both are staged here because this
> session was scoped to one repository. `agent-system/`, `deploy/`, `scripts/`
> and `docs/` are the second repo's contents, ready to be split out — no file
> moves needed, just `git mv` into a fresh clone.

## Rules

- **No secrets, ever.** Not keys, not tokens, not passwords, not full ID or
  card numbers. The agent's credentials live only in `$HERMES_HOME/.env`,
  which is git-ignored and backed up separately as an encrypted archive.
- One topic per file, descriptive kebab-case names, short enough to read in
  one screen.
- The agent commits and pushes here nightly at 03:15.

## Status

Phase 1 (install and configuration) is verified. Everything requiring an API
key, a Google account, a Telegram bot, or the Azure host is written but not
yet exercised — see the session notes and `docs/DEPLOY-AZURE.md`.
