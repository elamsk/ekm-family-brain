# Model-change checklist

Run through this whenever the primary model changes. Swapping `model:` in
`config.yaml` is one line; the things that line silently affects are not.

## 1. Re-check the auxiliary pins

`config.yaml` pins 15 auxiliary tasks. They do **not** follow the primary
model — that is the point of pinning — but a provider change can invalidate
them, because a pin naming a model the new provider does not serve fails at
call time, not at startup.

```bash
docker exec hermes-gateway hermes config get auxiliary | grep -E 'provider|model'
```

Confirm none has drifted back to `auto`. `auto` means Hermes walks
`main model → OpenRouter → Nous Portal → custom endpoint → Anthropic → direct
API-key providers` and binds whatever answers first — which is how an
auxiliary silently ends up on a model with the wrong context window or the
wrong price.

**Compression is the dangerous one.** It needs a large context window. If it
resolves to something small, compression fails partway through a long session,
and the place that surfaces is an unattended scheduled job.

## 2. Verify context windows

| Task | Needs |
|---|---|
| `compression` | 64K minimum; more is better |
| `web_extract` | large — a TikTok page plus transcript is not small |
| `session_search` | modest |
| `title_generation` | tiny |

## 3. Confirm tool calling

The primary model **must** support tool calling, and so must anything in
`fallback_providers`. A fallback that cannot call tools produces an agent that
answers questions but silently cannot check the calendar or write a file.

```bash
docker exec hermes-gateway hermes -z "List the files in /workspace/family-brain/food using your tools, then tell me how many there are."
```

A model without working tool use will guess a number. That is the failure to
watch for — it looks like success.

## 4. Announce the cost implications

Before switching, work out the new input price per million tokens and compare.
This workload is **read-heavy** — inbox, calendar, news, markdown brain — so
input price dominates and benchmark scores are close to irrelevant.

A rough monthly estimate:

```
daily news brief      ~30 runs   × input tokens
weekly cal preview    ~4  runs   × input tokens
ad-hoc Telegram       ~150 turns × input tokens
compression/aux       ~scales with session length
```

State the resulting change in plain money before making it, not after.

## 5. Re-test the fallback

A fallback that has never carried a real job is fiction. See Phase 9.1:

```bash
# Break the primary deliberately, then force a real scheduled job through.
docker exec hermes-gateway sh -c 'GEMINI_API_KEY=invalid hermes cron run <job-name>'
docker exec hermes-gateway hermes cron runs --limit 5
```

Confirm the run **completed** on the fallback rather than erroring.

## 6. Watch for silent skipping

If a spend guard, rate limiter, or drift guard can cause jobs to be skipped
rather than run, configure it to alert **loudly and repeatedly**. An
alert-once design fails exactly when you need it: you miss the single message,
and the agent is quietly dead for a week while appearing configured.

Prefer a job that fails noisily over a job that skips quietly.

## 7. Update the record

Note the change, the date, and the reason in this repo, so the next person
(you, in eight months) can see why the model is what it is.
