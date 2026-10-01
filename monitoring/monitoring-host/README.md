# Monitoring-host overlay

Config that belongs to the **central monitoring host**
(`olmismalawi-monitoring.soldevelo.com`, EC2 `i-0ab9da3156e01d648`), not to the
target hosts. The stack itself is the `soldevelo-monitoring` package, checked
out at `/opt/soldevelo-monitoring`; this directory holds the Malawi-specific
pieces the package deliberately doesn't carry.

`../alloy/` is the other side of the pair — what runs on each target host.

## `malawi.yml` — agent inventory

`AgentAbsent` for each of the three agent hosts. The package can't ship this:
it has no way to know which hosts a deployment expects. Deployed to:

```
/opt/soldevelo-monitoring/prometheus/rules/overlay/malawi.yml
```

That path is gitignored in the package (overlay files belong to the
deployment), which is why the master copy lives here.

## `blackbox/malawi-<env>.json` — HTTP probe targets

The targets are grouped by their `check` label:

- `check: public` is the environment's public URL and `check: app-direct` its
  load balancer root. The package's `AppDown` and `PublicUrlUnreachable` use
  this pair.
- `check: service` marks one probe per OpenLMIS service on the load balancer,
  with a `service` label. Every path (`/auth`, `/referencedata`, ...) returns
  that service's version JSON, so a 200 means the service itself answered
  through nginx. The probes go to the load balancer rather than the public URL,
  so a DNS problem does not look like a service outage. The `service` values
  match the `monitoring.service` scrape labels in the environment's
  `docker-compose.yml`. Each probe sets `__scrape_interval__: "60s"`, so it
  runs once a minute instead of every 15 s and adds fewer lines to the nginx
  access log.

`ServiceUnreachable`, the alert for the service probes, ships with the package:
it lives in `prometheus/rules/blackbox_http_rules.yml` in soldevelo-monitoring,
together with its unit tests. On a monitoring host running a package version
without that rule, the service probes alert nobody, because the package's
`ProbeFailing` ignores probes that carry a `check` label.

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
# expect: agent-inventory
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
