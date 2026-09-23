# ============================================================================
# Hermes family chief-of-staff.
#
# Design notes:
#  * HERMES_HOME is /data, which is a bind mount from the VM's own ext4 disk.
#    It is NOT on Azure Files. See docs/ARCHITECTURE.md — Hermes keeps ~12
#    SQLite DBs there and uses WAL, which does not work over SMB/CIFS.
#  * Runs as a non-root user. The agent has shell access to this container by
#    design; it should not have root in it.
# ============================================================================
FROM python:3.11-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HERMES_HOME=/data

# Runtime deps Hermes shells out to. ripgrep for search, ffmpeg for voice-memo
# transcription, git for the brain repo, gpg for the weekly encrypted backup.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl ripgrep ffmpeg gnupg zip unzip tzdata \
    && rm -rf /var/lib/apt/lists/*

# Pin the version. An always-on agent should not silently change brain
# surgeons because a new release landed overnight.
ARG HERMES_VERSION=0.19.0

# Extras, and why each is here. A bare `pip install hermes-agent` starts the
# gateway but cannot create ANY messaging adapter — it fails at runtime with
#   Platform 'Telegram' requirements not met (pip install 'hermes-agent[telegram]')
# That hint is wrong: 0.19.0 has no `telegram` extra. python-telegram-bot ships
# in `messaging`. Verified against the released metadata, not the message.
#
#   messaging -> python-telegram-bot (Telegram front door, Phase 7)
#   google    -> google-api-python-client + auth (Gmail/Calendar/Drive, Phase 3/6)
#   web       -> fastapi/uvicorn for `hermes serve` (the local-only web UI)
#
# Deliberately NOT `[all]`: it drags in computer-use, voice, and a dozen
# integrations we do not use — a slower build on a 2 GiB VM and more surface
# on a host holding our credentials.
ARG HERMES_EXTRAS=messaging,google,web
RUN pip install --no-cache-dir "hermes-agent[${HERMES_EXTRAS}]==${HERMES_VERSION}"

RUN useradd --create-home --uid 10001 hermes \
    && mkdir -p /data /workspace \
    && chown -R hermes:hermes /data /workspace

USER hermes
WORKDIR /workspace
VOLUME ["/data", "/workspace"]

# Foreground gateway — the mode Hermes documents for Docker. It supervises the
# messaging platforms and the cron scheduler in one process.
CMD ["hermes", "gateway", "run"]
