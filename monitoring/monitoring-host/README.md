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

Verify it loaded:

```sh
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[].name'
# expect: agent-inventory
```

## Updating the stack itself

```sh
cd /opt/soldevelo-monitoring
git pull
bin/render-configs.sh .env
docker compose --env-file .env -f stack/docker-compose.yml up -d \
  --force-recreate alertmanager prometheus-meta
curl -X POST localhost:9090/-/reload
```

`prometheus` reloads in place (`--web.enable-lifecycle`); `prometheus-meta` has
no lifecycle flag and must be recreated. Compose on that host needs
`--env-file .env` explicitly — it reads `.env` from the compose file's
directory, not the repo root.

## Dead man's switch

Not yet configured. `WATCHDOG_RECEIVER` and `HEARTBEAT_URL` are unset in the
host's `.env`, so the always-firing `Watchdog` alert is routed to a receiver
that discards it. Until they point at an external heartbeat endpoint, a failure
of the monitoring host itself is undetectable — silence from this stack cannot
be distinguished from a healthy system. See
`soldevelo-monitoring/docs/dead-man-switch.md`.
