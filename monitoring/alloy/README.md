# Grafana Alloy agent (OpenLMIS Malawi monitoring)

One Alloy agent per environment host. It discovers the OpenLMIS containers
(via `monitoring.*` labels), collects host + container + app metrics, all
container logs and the nginx access/error log files, and pushes them to the
central monitoring host over authenticated HTTPS. Part of the `soldevelo-monitoring` migration (MW-1471).

Runs as its own compose project, separate from the app stack — so it isn't
recreated on every service deploy.

## Config files

| File | What |
|---|---|
| `config.alloy` | The `soldevelo-monitoring` package agent, **vendored** at the tag in `PACKAGE_VERSION`. Never edit it here. |
| `malawi.alloy` | Malawi additions: the nginx file logs. |
| `PACKAGE_VERSION` | Package tag `config.alloy` was copied from. |
| `sync-from-package.sh` | Re-copies `config.alloy` for that tag; `--check` reports drift. |

Both `.alloy` files are baked into the image and loaded as one config from
`/etc/alloy`. To upgrade: bump `PACKAGE_VERSION`, run `./sync-from-package.sh`,
read the diff and the package CHANGELOG, commit, deploy dev → uat → prod.

## Prerequisites

- The environment's app stack is up (its docker network exists — that's `APP_NETWORK`).
- The Java services carry the `monitoring.*` scrape labels (see PR labelling `uat_env`).
- The central stack is reachable at `INGEST_METRICS_URL` / `INGEST_LOGS_URL` and the
  bearer token matches the monitoring host's `INGEST_TOKEN`.

## Deploy (per environment, via the remote Docker daemon)

You do **not** put anything on the target host. Run this from wherever you run the
app deploy (Jenkins, or a workstation with this repo checked out and the Docker-TLS
certs) — the same remote-daemon model as `deploy_to_uat_env.sh`. `config.alloy` is
baked into the image via the build context and sent to the remote daemon, so no file
placement on the host is needed.

```sh
cp .env.example .env
# then edit .env:
#   ENVIRONMENT / TARGET_NAME  -> dev (malawi-dev), uat (malawi-uat) or prod (malawi-prod)
#   APP_NETWORK                -> confirm with `docker network ls` on the host
#   INGEST_TOKEN               -> the value from the monitoring host's .env (keep secret)

# point at the environment's Docker daemon (same certs/host as the app deploy)
export DOCKER_TLS_VERIFY=1
export DOCKER_HOST=lmis-uat.health.gov.mw:2376      # lmis-dev… for dev, prod host for prod
export DOCKER_CERT_PATH=/path/to/credentials

docker-compose up -d --build           # --build bakes config.alloy in; rebuild after any config change
docker-compose logs --tail=50 alloy    # expect no 4xx to the /ingest endpoints
```

`INGEST_TOKEN` should be delivered the same way as the app's secrets (private
config repo / Jenkins), never committed. `.env` is gitignored.

## Jenkins / automated deploy (the intended path)

A Jenkins job checks out this repo + `malawi-configuration` (the env branch, into
`credentials/`) and runs `deploy_alloy.sh`, which mirrors the app's
`deploy_to_*_env.sh`:

- Per-environment config + secrets live in **`malawi-configuration`'s env branch as
  `alloy.env`** (copied to `./.env` at deploy time) — it holds `INGEST_TOKEN`,
  `DOCKER_HOST`, `APP_NETWORK`, `ENVIRONMENT`, `TARGET_NAME`, the ingest URLs, etc.
  (same delivery model as the app's `.env`). Never commit it here.
- `deploy_alloy.sh` loads it, points at that env's Docker daemon over TLS
  (certs from `credentials/`), and runs `docker-compose up -d --build`.

`.env.example` here documents the variables for manual/local runs; in Jenkins the
real values come from `malawi-configuration`.

## Verify (on the monitoring host / Grafana Explore)

- `count by (environment) (up)` shows one series per deployed agent (`dev`, `uat`, `prod`).
- `up{environment="uat"}` — every labelled service reports `1`.
- Host/container metrics: `node_uname_info{host="malawi-uat"}`, cAdvisor series.
- Logs: `{environment="uat"}` in Loki.
- nginx access log: `{container="nginx"} |= "HTTP/1.1"` — the only stream read from
  files, not container stdout. Up to 30 s behind (nginx buffers with `flush=30s`).

## Notes

- `COMPOSE_PROJECT_NAME=soldevelo-monitoring-agents` (in `.env`) must stay stable —
  `config.alloy` drops the agent's own logs by that project name (self-loop guard).
- The nginx reverse proxy logs to files in the `nginx-log` volume and nothing to
  stdout, so `malawi.alloy` tails `/var/lib/docker/volumes/*_nginx-log/_data/*.log`
  through the `/var/lib/docker` mount cAdvisor already needs. ELB health checks are
  dropped; `tail_from_end` keeps the unrotated 400 MB+ `access.log` from backfilling.
- The `scalyr` container's own stdout is dropped by `LOG_DROP_SERVICES=scalyr` in
  `alloy.env`: ~385 lines/min of a failing tcollector plugin, ~588k lines/day/env of
  no signal. Clear the value with DataSet.
- Alloy joins `APP_NETWORK` to reach container IPs; it scrapes each labelled
  container at `monitoring.port` + `monitoring.path` — `/actuator/prometheus` on the
  Boot 2 services, `/prometheus` on the Boot 1.5 forks (reports, dhis2-integration).
- Compose file is v2.4 syntax because Jenkins runs `docker-compose` 1.23.2, which
  cannot read the package's `agents-alloy/docker-compose.yml`. Only the config is
  shared with the package, not the compose file.
