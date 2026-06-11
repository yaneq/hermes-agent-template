# Zonic fork of hermes-agent-template

Forked from https://github.com/praveen-ks-2001/hermes-agent-template (state of 2026-06-11,
the revision deployed as the Zoni trial container) to run **`hermes gateway run` as the
service's main process**, supervised directly by Railway's restart policy.

## Why fork

The upstream template runs an admin web server (`server.py`) as the main process, which
manages `hermes gateway` as a subprocess. Two problems for our deployment (found during
the 2026-06-11 OpenClaw→Hermes migration):

1. **Config clobbering.** Every managed gateway start (boot auto-start, admin-UI
   Start/Restart, setup wizard) calls `write_config_yaml()`, which force-overwrites
   `model.default` (from `.env`'s `LLM_MODEL`), forces `model.provider: auto`, and resets
   `terminal.cwd` to `/tmp` + `terminal.timeout` to 60. Our config uses the native
   `gemini` provider and `terminal.cwd: /data/.hermes/workspace` (knowledge-base context
   injection) — a managed start silently breaks both.
2. **Auto-start gaps.** `is_config_complete()` only recognizes `LLM_MODEL` + a hardcoded
   provider-key list (knows `GEMINI_API_KEY`, not `GOOGLE_API_KEY`). Config living in
   `config.yaml` (the hermes-native way) is invisible to it, so the gateway never
   auto-starts after a container restart and the bot silently stays down.

## What changed

- **`start.sh`** — keeps all the volume-prep steps (dir creation, `.install_method`
  stamp, config seeding, auth bootstrap, stale `gateway.pid` cleanup), then
  `exec hermes gateway run` instead of `exec python /app/server.py`.
  New pre-flight: if no messaging platform is configured in `.env`, idle
  (`sleep infinity`) instead of crash-looping, so a fresh volume can be configured
  via `railway shell`.
- **`Dockerfile`** — drops `server.py`, `templates/`, and `requirements.txt`
  (admin-server-only deps). Everything else (hermes install, tini, TUI prebuild)
  unchanged.
- **`railway.toml`** — removes `healthcheckPath` (no HTTP server anymore); restart
  policy unchanged (`on_failure`, 10 retries) and now supervises the gateway itself.
- **Removed:** `server.py`, `templates/`, `requirements.txt`.

## Operational notes

- Config is owned by the volume: `/data/.hermes/config.yaml` + `/data/.hermes/.env`.
  Nothing rewrites them at boot.
- No web UI is exposed. Remove the service's public domain in Railway settings
  (nothing listens on PORT). For an ad-hoc dashboard: `railway shell` →
  `hermes dashboard --host 0.0.0.0 --port 8080` (temporary).
- Upgrades: bump `HERMES_REF` in the Dockerfile and redeploy (same as upstream).
- Graceful shutdown: tini forwards Railway's SIGTERM to the gateway, which drains
  in-flight agent turns (`agent.restart_drain_timeout` in config.yaml).
- Logs: gateway logs go to stdout → Railway's log view (plus
  `/data/.hermes/logs/gateway.log` as before).

## Deploy steps (switching the existing Zoni trial service)

1. Push this directory to a repo you own (e.g. `zonic/hermes-agent-template`).
2. In the Railway service: disconnect the upstream template repo, connect the fork.
3. Make sure no manually-started gateway is running in the old container (it will be
   replaced by the redeploy anyway — the deploy kills the container).
4. Redeploy. Boot order: volume prep → pre-flight (Slack token present → proceed) →
   `hermes gateway run` becomes the main process and reconnects to Slack.
5. Validate: Railway logs show "✓ slack connected"; `@Zoni ping` in #dev; restart the
   service once and confirm it comes back on its own.
