#!/bin/bash
set -e

# Zonic fork: this template runs `hermes gateway run` as the service's MAIN
# process — no admin web server, no managed-subprocess supervision. Railway's
# restart policy supervises the gateway directly: if it dies, the container
# exits and Railway restarts it. Config is owned by the persistent volume
# (/data/.hermes/config.yaml + .env) and is NEVER rewritten at boot — the
# upstream template's server.py force-rewrote model/provider/terminal.cwd on
# every managed start, which clobbered hand-tuned configs (native gemini
# provider, workspace cwd). That whole path is removed in this fork.

# Create every directory hermes expects and seed a default config.yaml if the
# volume is empty. Without these, hermes endpoints that hit logs/, sessions/,
# cron/, etc. can fail with opaque errors.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace /data/.hermes/skins /data/.hermes/plans \
         /data/.hermes/home

# Stamp the install method as "docker" so hermes treats this as an immutable
# container image, not a pip checkout. hermes's detect_install_method() reads
# $HERMES_HOME/.install_method FIRST (before any .git / pip fallback). Without
# this stamp the template falls through to "pip" — because the Dockerfile strips
# /opt/hermes-agent/.git — and `hermes update` would run a real PyPI pip-upgrade
# INSIDE the running container. That upgrade is ephemeral (reverts on the next
# redeploy) and can desync the Python package from the image's pre-built
# web_dist/ui-tui bundles. Stamping "docker" makes update correctly refuse with
# "pull a fresh image / redeploy", which matches the real upgrade path here
# (bump HERMES_REF in Railway + redeploy). Written unconditionally each boot.
printf 'docker\n' > /data/.hermes/.install_method

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f /data/.hermes/auth.json ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > /data/.hermes/auth.json
  chmod 600 /data/.hermes/auth.json
fi

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

# Pre-flight: on a fresh/unconfigured volume the gateway has no platform to
# serve and would crash-loop through Railway's restart budget. Idle instead,
# so the operator can configure /data/.hermes/.env + config.yaml via
# `railway shell` (or `railway ssh`), then restart the service.
if ! grep -qE '^(SLACK_BOT_TOKEN|TELEGRAM_BOT_TOKEN|DISCORD_BOT_TOKEN|WHATSAPP_ENABLED|MATTERMOST_TOKEN|MATRIX_ACCESS_TOKEN|SIGNAL_ACCOUNT)=..*' /data/.hermes/.env; then
  echo "[start] No messaging platform configured in /data/.hermes/.env — idling (no crash loop)."
  echo "[start] Shell in, configure .env + config.yaml, then restart the service."
  exec sleep infinity
fi

# Need an ad-hoc dashboard? Shell in and run:
#   hermes dashboard --host 0.0.0.0 --port 8080
# (then use Railway private networking / port-forward; nothing is exposed by default)

echo "[start] Starting hermes gateway as the service main process"
echo "[start] Config owner: /data/.hermes/config.yaml + /data/.hermes/.env (never rewritten at boot)"
exec hermes gateway run
