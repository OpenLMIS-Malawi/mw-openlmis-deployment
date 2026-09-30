# Monitoring-host overlay

Config that belongs to the **central monitoring host**
(`olmismalawi-monitoring.soldevelo.com`, EC2 `i-0ab9da3156e01d648`), not to the
target hosts. The stack itself is the `soldevelo-monitoring` package, checked
out at `/opt/soldevelo-monitoring`; this directory holds the Malawi-specific
pieces the package deliberately doesn't carry.

`../alloy/` is the other side of the pair — what runs on each target host.

## `malawi.yml` — alert rules

Deployed to:

```
/opt/soldevelo-monitoring/prometheus/rules/overlay/malawi.yml
```

That path is gitignored in the package (overlay files belong to the
deployment), which is why the master copy lives here. The file has two groups:

- `agent-inventory`: `AgentAbsent` for each of the three agent hosts. The
  package can't ship this, because it has no way to know which hosts a
  deployment expects.
- `service-probes`: `ServiceUnreachable` (critical) fires when a service probe
  (`check: service`, see below) has failed for 5 minutes while the app-direct
  probe of the same environment still succeeds. A whole-application outage is
  left to the package's `AppDown`, so it arrives as one alert instead of one per
  service. The package's `ProbeFailing` ignores probes that carry a `check`
  label, so without this rule a failing service probe would alert nobody.

`tests/malawi_rules_test.yml` holds promtool unit tests for
`ServiceUnreachable`. Run them from the repository root:

```sh
docker run --rm -v "$PWD/monitoring/monitoring-host:/work:ro" -w /work/tests \
  --entrypoint promtool prom/prometheus:v2.55.1 test rules malawi_rules_test.yml
```

## `blackbox/malawi-<env>.json` — HTTP probe targets

The targets are grouped by their `check` label:

- `check: public` is the environment's public URL and `check: app-direct` its
  load balancer root. The package's `AppDown` and `PublicUrlUnreachable` use
  this pair.
- `check: service` marks one probe per OpenLMIS service on the load balancer.
  Each carries a `service` label, and `ServiceUnreachable` alerts on them.
  Every path (`/auth`, `/referencedata`, ...) returns that service's version
  JSON, so a 200 means the service itself answered through nginx. The probes go
  to the load balancer rather than the public URL, so a DNS problem does not
  look like a service outage. The `service` values match the
  `monitoring.service` scrape labels in the environment's `docker-compose.yml`.

Deployed to:

```
/opt/soldevelo-monitoring/prometheus/targets/blackbox/malawi-<env>.json
```

Also gitignored in the package. Prometheus re-reads the directory every 30 s,
so a changed file needs no reload.

## Deploying it

The monitoring host is SSM-only — no SSH. From a machine with the
`openlmis-malawi` AWS profile:

```sh
aws ssm send-command --profile openlmis-malawi --region eu-west-1 \
  --instance-ids i-0ab9da3156e01d648 --document-name AWS-RunShellScript \
  --parameters commands='["cat > /opt/soldevelo-monitoring/prometheus/rules/overlay/malawi.yml <<'\''EOF'\''
<paste malawi.yml here>
EOF
curl -X POST localhost:9090/-/reload"]'
```

The target files go to `/opt/soldevelo-monitoring/prometheus/targets/blackbox/`
the same way and need no reload.

Verify it loaded:

```sh
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[].name'
# expect: agent-inventory and service-probes
```

## Updating the stack itself

The host tracks package tags. Check the current one with `git describe --tags`.

```sh
cd /opt/soldevelo-monitoring
git fetch --tags origin && git checkout vX.Y.Z
bin/render-configs.sh && bin/validate.sh .env
docker compose --env-file .env -f stack/docker-compose.yml up -d --force-recreate
```

Run it with `bash` and `set -e`, and never pipe `validate.sh` (a `| tail`
hides its exit code). Compose on that host needs `--env-file .env`
explicitly — it reads `.env` from the compose file's directory, not the repo
root. The overlay files survive a checkout, since the package ignores them.

## Dead man's switch

Not yet configured. `WATCHDOG_RECEIVER` and `HEARTBEAT_URL` are unset in the
host's `.env`, so the always-firing `Watchdog` alert is routed to a receiver
that discards it. Until they point at an external heartbeat endpoint, a failure
of the monitoring host itself is undetectable — silence from this stack cannot
be distinguished from a healthy system. See
`soldevelo-monitoring/docs/dead-man-switch.md`.
