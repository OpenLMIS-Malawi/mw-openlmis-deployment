# Grafana Alloy agent (OpenLMIS Malawi monitoring)

One Alloy agent per environment host. It discovers the OpenLMIS containers
(via `monitoring.*` labels), collects host + container + app metrics and all
container logs, and pushes them to the central monitoring host over
authenticated HTTPS. Part of the `soldevelo-monitoring` migration (MW-1471).

Runs as its own compose project, separate from the app stack — so it isn't
recreated on every service deploy.

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
#   ENVIRONMENT / TARGET_NAME  -> uat (malawi-uat) or prod (malawi-prod)
#   APP_NETWORK                -> confirm with `docker network ls` on the host
#   INGEST_TOKEN               -> the value from the monitoring host's .env (keep secret)

# point at the environment's Docker daemon (same certs/host as the app deploy)
export DOCKER_TLS_VERIFY=1
export DOCKER_HOST=lmis-uat.health.gov.mw:2376      # prod host for the prod agent
export DOCKER_CERT_PATH=/path/to/credentials

docker-compose up -d --build           # --build bakes config.alloy in; rebuild after any config change
docker-compose logs --tail=50 alloy    # expect no 4xx to the /ingest endpoints
```

`INGEST_TOKEN` should be delivered the same way as the app's secrets (private
config repo / Jenkins), never committed. `.env` is gitignored.

## Verify (on the monitoring host / Grafana Explore)

- `count by (environment) (up)` shows `uat` (and `prod` once that agent is up).
- `up{environment="uat"}` — the 8 labelled services report `1`.
- Host/container metrics: `node_uname_info{host="malawi-uat"}`, cAdvisor series.
- Logs: `{environment="uat"}` in Loki.

## Notes

- `COMPOSE_PROJECT_NAME=soldevelo-monitoring-agents` (in `.env`) must stay stable —
  `config.alloy` drops the agent's own logs by that project name (self-loop guard).
- Alloy joins `APP_NETWORK` to reach container IPs; it scrapes each labelled
  container at `monitoring.port` + `monitoring.path` (`:8080/actuator/prometheus`).
- Adapted from the `soldevelo-monitoring` `agents-alloy/` bundle, plus an
  `environment` external label for the shared UAT+Prod monitoring host.
