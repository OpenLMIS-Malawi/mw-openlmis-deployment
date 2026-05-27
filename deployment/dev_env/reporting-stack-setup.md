# Reporting-stack deployment — Malawi dev

End-to-end runbook for replacing the legacy Nifi-based reporting stack on
`reporting-lmis-dev.health.gov.mw` with the new openlmis-reporting platform,
running co-located with OpenLMIS on `lmis-dev.health.gov.mw`.

This is the **dev** rollout. UAT and prod follow the same pattern; do not
copy this to prod without first repeating the RDS preflight there.

---

## Architecture after the change

```
                            lmis-dev.health.gov.mw
                            ┌────────────────────────────────────┐
RDS PG14                    │  OpenLMIS services (compose proj 1)│
malawi-dev-postgresql-db    │  ─ requisition, referencedata, ... │
        │                   │                                    │
        └─ logical          │  Reporting-stack (compose proj 2)  │
           replication ───▶ │  ─ kafka, kafka-connect (Debezium) │
                            │  ─ clickhouse                      │
                            │  ─ airflow, superset               │
                            └────────────────────────────────────┘
```

Source DB stays on RDS. Both compose projects share the same Docker daemon
but are isolated by project name (`name: soldevelo-reporting-stack` in the
reporting-stack compose file) — no name collisions.

Old host `reporting-lmis-dev.health.gov.mw` is decommissioned later. DNS can
be swung to point at `lmis-dev` if/when we want OAuth-style SSO to work
again (see "Follow-ups" below).

---

## Repos involved

| Repo                                | Branch              | What changes                                                                                                   |
| ----------------------------------- | ------------------- | -------------------------------------------------------------------------------------------------------------- |
| `mw-openlmis-deployment` (public)   | new feature branch  | `deployment/dev_env/deploy_to_dev_env.sh` (extends), plus this runbook                                          |
| `malawi-configuration` (private)    | new feature branch  | New `.env.reporting-stack`                                                                                      |
| `openlmis-reporting` (public)       | `main` is fine; optionally a feature branch if connector template needs SSL | (Optional) add `database.sslmode` to the connector JSON template                                                |

Jenkins job: clone the existing `dev` job, change SCM checkouts and branch
parameter on the clone — leave the original job intact for fallback.

---

## Step 0 — Host prep (one-time, per instance)

These steps prepare a Malawi OLMIS host to also run the reporting-stack. They
are **repeatable** — run them on any target (dev/uat/prod or a fresh box). All
commands are idempotent and safe to re-run.

> **Context — what the dev box looked like (2026-05-27).** `lmis-dev` is an AWS
> `r5.large` (2 vCPU / 16 GB), Ubuntu 16.04 (Xenial, EOL), Docker `19.03.5`
> installed from download.docker.com, OLMIS running as 16 `dev_env_*`
> containers via compose **v1** over remote TLS. The procedure below was shaped
> by that environment; notes call out where a newer OS lets you take a shortcut.

Connect with the deployment SSH key (from `malawi-configuration`). The key
arrives from git at mode 0664 — chmod it before use:

```bash
chmod 600 malawi-configuration/id_rsa
ssh -i malawi-configuration/id_rsa ubuntu@<host>     # e.g. lmis-dev.health.gov.mw
```

### 0a. Verify capacity

```bash
ssh -i malawi-configuration/id_rsa ubuntu@<host> '
  curl -s http://169.254.169.254/latest/meta-data/instance-type; echo
  nproc; free -h; df -h /
  sudo docker ps --format "{{.Names}}" | wc -l   # OLMIS containers already running
'
```

Budget ~4–5 GB RAM and meaningful CPU for the reporting-stack on top of OLMIS.
On `r5.large` (2 vCPU) it runs but the initial snapshot + dbt builds are slow.
If the workload proves CPU-bound in practice, resize the instance
(`r5.large` → `r5.xlarge` doubles vCPU+RAM) — note a resize needs a
stop/start, so confirm an Elastic IP / ELB keeps the DNS name stable first.

### 0b. Verify base tooling

```bash
ssh -i malawi-configuration/id_rsa ubuntu@<host> 'command -v make rsync git docker'
```

All four are present on a standard OLMIS host. `make`, `rsync`, `git` are used
by the deploy script; `docker` is the engine.

### 0c. Install Docker Compose v2 (standalone plugin binary)

The Makefile uses `docker compose` (v2). On Xenial the `docker-compose-plugin`
apt package is **not available**, so install the binary directly — one
self-contained file, no apt, cannot restart the daemon (OLMIS is untouched).
The old v1 binary at `/usr/local/bin/docker-compose` (used by the OLMIS deploy)
is left in place; both coexist.

```bash
ssh -i malawi-configuration/id_rsa ubuntu@<host> '
  set -e
  VER=v2.21.0   # conservative release; confirmed working against Docker 19.03 (API 1.40)
  ARCH=$(uname -m)
  URL="https://github.com/docker/compose/releases/download/${VER}/docker-compose-linux-${ARCH}"
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -fSL "$URL" -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  docker compose version
'
```

> On a modern OS (Ubuntu 20.04+ with the Docker apt repo configured) you can
> instead `sudo apt-get install -y docker-compose-plugin`. The binary method
> above is the universal fallback and is what dev uses.

> **Why v2.21.0:** Compose v2 negotiates the Docker API down to the daemon's
> version, so even this old `19.03.5` engine works. v2.21.0 (Sept 2023) is a
> conservative, well-tested pin — verified in 0f below.

### 0d. Give the deploy user Docker socket access

The deploy script runs `make up` over SSH **as `ubuntu`** (unlike the OLMIS
deploy, which talks to the daemon remotely over TLS). `ubuntu` therefore needs
the `docker` group. This grants no new privilege on a host where `ubuntu`
already has passwordless sudo, and it does not touch the daemon or OLMIS.

```bash
ssh -i malawi-configuration/id_rsa ubuntu@<host> 'sudo usermod -aG docker ubuntu'
```

Group membership applies at the **next** login — a fresh SSH session (which is
what every Jenkins run opens) picks it up. Reverse with
`sudo gpasswd -d ubuntu docker`.

### 0e. Add swap (OOM safety net)

With 0 swap, a memory spike makes the kernel kill a process outright — possibly
an OLMIS container. A 4 GB swap **file** on the existing EBS volume costs
nothing extra (EBS is billed by provisioned size, already paid) and is purely
insurance, not capacity. `swappiness=10` keeps the kernel off swap until real
pressure.

```bash
ssh -i malawi-configuration/id_rsa ubuntu@<host> 'sudo bash -s' <<'REMOTE'
set -euo pipefail
if ! swapon --show | grep -q .; then
  [ -f /swapfile ] || fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl -w vm.swappiness=10 >/dev/null
grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
swapon --show; free -h
REMOTE
```

### 0f. Verify host prep end-to-end (fresh session)

A **new** SSH session confirms the docker-group change took effect, the socket
is reachable without sudo, and Compose v2 can actually drive the old daemon:

```bash
ssh -i malawi-configuration/id_rsa ubuntu@<host> '
  id | grep -o docker                 # ubuntu is in the docker group
  docker compose version              # plugin recognized
  docker ps >/dev/null && echo "socket OK as ubuntu"
  docker compose ls                   # KEY: compose v2 talks to the daemon (lists dev_env)
  swapon --show                       # swap active
'
```

A benign `No label "com.docker.compose.project.config_files"` warning on
`docker compose ls` is expected — it just means OLMIS was created with compose
v1. It does not affect the reporting-stack project.

### 0g. Create the deploy target directory

```bash
ssh -i malawi-configuration/id_rsa ubuntu@<host> 'sudo mkdir -p /opt/reporting-stack && sudo chown ubuntu:ubuntu /opt/reporting-stack'
```

The deploy script also does this, but pre-creating surfaces any permission
issue outside a Jenkins run. Path must match `REPORTING_REMOTE_PATH` in
`deploy_to_dev_env.sh` and `REPORTING_HOST_ROOT` in `.env.reporting-stack`.

---

## Step 1 — RDS preflight (one-time)

The Malawi dev DB is RDS PG14, parameter group `postgres14`. Logical
replication is almost certainly off — none of the OLMIS services need it.

### 1a. Enable logical replication on the parameter group

In AWS console (or via CLI), edit parameter group `postgres14`:

| Parameter                          | Value | Notes                                              |
| ---------------------------------- | ----- | -------------------------------------------------- |
| `rds.logical_replication`          | `1`   | Required. Static — sets `wal_level=logical`, needs reboot. |
| `max_wal_senders`                  | `20`  | Already 20 on dev — leave as-is.                   |
| `max_replication_slots`            | `20`  | Already 20 on dev — leave as-is.                   |
| `max_logical_replication_workers`  | `4`   | Optional, only matters if many subscribers.        |

> On the dev box, `max_wal_senders`/`max_replication_slots` were already 20, so
> `rds.logical_replication=1` is the only required change. If the attached group
> is `default.postgres14` it cannot be edited — create a custom group, set the
> parameter, and associate it (association also requires a reboot).

### 1b. Reboot the RDS instance

```
aws rds reboot-db-instance --db-instance-identifier malawi-dev-postgresql-db --region us-east-1
```

Confirm `wal_level=logical` is in effect once the instance is up:
```
psql "postgresql://mw_user@malawi-dev-postgresql-db.ckvxhrmwuhtv.us-east-1.rds.amazonaws.com:5432/malawi_openlmis?sslmode=require" \
     -c "SHOW wal_level;"
```

### 1c. Grant replication privilege

`mw_user` is the master user (has `rds_superuser`) but does NOT have the
replication attribute by default (confirmed `rolreplication = f` on dev).
On RDS the master user is not a true superuser, so `ALTER ROLE ... WITH
REPLICATION` **fails** — use the RDS role grant instead:
```sql
GRANT rds_replication TO mw_user;
```
Verify:
```
psql ... -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname='mw_user';"
```
Note: `rolreplication` may still read `f` after the grant — RDS authorizes
replication via the `rds_replication` role membership rather than the role
attribute, and Debezium connects fine with it. The real test is the connector
creating its slot at deploy time.

### 1d. Create publication, signal, and heartbeat objects

Connect to `malawi_openlmis` as `mw_user`, run the SQL below. It's idempotent
and mirrors `openlmis-ref-distro/reporting-stack/init-db.sql` from the
reporting-stack platform, but adapted to apply directly to RDS.

```sql
-- Heartbeat: prevents WAL accumulation during idle periods
CREATE TABLE IF NOT EXISTS public.reporting_heartbeat (
  id INT PRIMARY KEY DEFAULT 1,
  ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO public.reporting_heartbeat (id, ts) VALUES (1, NOW())
  ON CONFLICT (id) DO NOTHING;

-- Signal table: triggers Debezium incremental snapshots
CREATE TABLE IF NOT EXISTS public.debezium_signal (
  id   VARCHAR(42)  PRIMARY KEY,
  type VARCHAR(32)  NOT NULL,
  data VARCHAR(2048)
);

-- Publication
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'dbz_publication') THEN
    CREATE PUBLICATION dbz_publication FOR TABLE
      public.debezium_signal,
      referencedata.facilities,
      referencedata.programs,
      referencedata.geographic_zones,
      referencedata.orderables,
      referencedata.processing_periods,
      referencedata.processing_schedules,
      referencedata.facility_types,
      referencedata.supported_programs,
      referencedata.requisition_group_members,
      referencedata.requisition_group_program_schedules,
      requisition.requisitions,
      requisition.requisition_line_items,
      requisition.status_changes,
      requisition.stock_adjustments,
      requisition.stock_adjustment_reasons;
  END IF;
END $$;

-- Re-set the table list to handle drop-and-recreate (e.g. Flyway re-init).
ALTER PUBLICATION dbz_publication SET TABLE
  public.debezium_signal,
  referencedata.facilities,
  referencedata.programs,
  referencedata.geographic_zones,
  referencedata.orderables,
  referencedata.processing_periods,
  referencedata.processing_schedules,
  referencedata.facility_types,
  referencedata.supported_programs,
  referencedata.requisition_group_members,
  referencedata.requisition_group_program_schedules,
  requisition.requisitions,
  requisition.requisition_line_items,
  requisition.status_changes,
  requisition.stock_adjustments,
  requisition.stock_adjustment_reasons;
```

Verify:
```
psql ... -c "SELECT pubname FROM pg_publication;"
psql ... -c "SELECT count(*) FROM pg_publication_tables WHERE pubname='dbz_publication';"
```

### 1e. RDS security group

The reporting-stack's `kafka-connect` container will reach RDS through the
EC2 host's egress. Confirm:
- The RDS security group allows inbound on 5432 from the `lmis-dev` EC2's
  security group or its private IP. This rule should already exist (OLMIS
  uses the same DB).

---

## Step 2 — Connector SSL (already wired, env-driven)

This is **done** in the platform repo (branch `dev-reporting-stack`). The
connector template now reads `"database.sslmode": "${SOURCE_PG_SSLMODE}"`,
`register-connector.sh` defaults it to `prefer`, and the Malawi
`.env.reporting-stack` sets `SOURCE_PG_SSLMODE=require`. No template edit is
needed at deploy time.

Why `require`: RDS accepts both SSL and plaintext by default, but if the
`postgres14` parameter group has `rds.force_ssl=1`, plaintext is **rejected**
and the connector would fail without it. `require` encrypts in transit with no
extra setup. `verify-full` (server-cert verification) is a later hardening
step — it needs the RDS CA bundle mounted into the kafka-connect image.

Check whether SSL is merely good practice or strictly mandatory here:
```
psql ... -c "SHOW rds.force_ssl;"
```

---

## Step 3 — `.env.reporting-stack` in `malawi-configuration`

A draft already exists at `malawi-configuration/.env.reporting-stack` (this
PR or branch). Before deploying:

1. Open it and replace every `<GENERATE ...>` placeholder. Suggested:
   ```
   openssl rand -base64 24       # passwords
   openssl rand -base64 48       # SUPERSET_SECRET_KEY
   python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"  # Fernet
   ```
2. Replace `<COPY POSTGRES_PASSWORD FROM .env>` with the value of
   `POSTGRES_PASSWORD` from `malawi-configuration/.env` (line 35 at time of
   writing). Don't commit the placeholder; the deploy will fail on it.
3. Commit on a feature branch of `malawi-configuration`.
4. Keep this file in sync with `.env` whenever the OLMIS DB password rotates.

---

## Step 4 — Jenkins job

**Don't modify the existing `dev` job — clone it.**

**Workspace layout the deploy script expects.** All three SCMs check out
*under* the Jenkins workspace root. The deployment repo sits at the root; the
other two MUST be placed in their own subdirectories or they collide with the
deployment repo's files at the root:

```
$WORKSPACE/                       <- mw-openlmis-deployment  (no subdir)
├── deployment/dev_env/...
├── credentials/                  <- malawi-configuration    (subdir "credentials")
│   ├── .env
│   ├── .env.reporting-stack
│   └── id_rsa
└── openlmis-reporting/           <- soldevelo-reporting-stack (subdir "openlmis-reporting")
```

The script resolves these via `$WORKSPACE` (`credentials/` and
`openlmis-reporting/`). If you must use a different subdirectory name for the
reporting repo, set `REPORTING_REPO_LOCAL` as a job env var to match.

1. In Jenkins, copy the `dev` job → name it e.g. `dev-with-reporting-stack`.
2. On the clone, add a **third SCM checkout** for `soldevelo-reporting-stack`:
   - Repository URL: the openlmis-reporting Git URL
   - Branch specifier: `*/dev-reporting-stack`
   - **Checkout to a sub-directory: `openlmis-reporting`** (Git plugin →
     Additional Behaviours → "Check out to a sub-directory"). This is
     REQUIRED — without it the repo checks out to the workspace root and
     collides with mw-openlmis-deployment.
   - Confirm `malawi-configuration` already checks out to sub-directory
     `credentials`, and `mw-openlmis-deployment` checks out to the root
     (no sub-directory).
3. On the clone, change branch parameters:
   - `mw-openlmis-deployment` → `*/<your feature branch>` (containing the
     extended `deploy_to_dev_env.sh` and this runbook)
   - `malawi-configuration` → `*/<your feature branch>` (containing
     `.env.reporting-stack`)
4. Verify the existing `KEEP_OR_WIPE` choice parameter is preserved.
5. (Optional) Add a choice parameter `SKIP_REPORTING_STACK=0|1` — handy for
   OLMIS-only redeploys while iterating.
6. Save and trigger a manual build with `KEEP_OR_WIPE=keep`.

The shell step does not need to change. The existing
`cd ./deployment/dev_env/ && ./deploy_to_dev_env.sh` is enough — the
extended script handles both stacks.

---

## Step 5 — First deploy

Trigger the cloned Jenkins job with `KEEP_OR_WIPE=keep`.

Expected log timeline:
1. `init_env.sh` copies OLMIS `.env`
2. `docker-compose pull` for OLMIS images
3. `restart_or_restore.sh` → `restart.sh` brings OLMIS up (no DB wipe)
4. **NEW**: rsync openlmis-reporting → `ubuntu@lmis-dev:/opt/reporting-stack`
5. **NEW**: `make up` on remote — pulls Kafka/ClickHouse/Airflow/Superset
   images (a few minutes the first time), starts services
6. **NEW**: `make setup` — registers Debezium connector, initializes
   ClickHouse raw tables, waits for snapshot, runs dbt build, imports
   Superset dashboards
7. **NEW**: verification scripts confirm each layer

First snapshot can take a while depending on table sizes. The largest table
(`requisition_line_items` historically) usually dominates.

---

## Step 6 — Verify end-to-end

From the Jenkins agent or your laptop (over SSH to `lmis-dev`):

```bash
ssh ubuntu@lmis-dev.health.gov.mw '
  cd /opt/reporting-stack &&
  make ps &&
  make verify-services &&
  make verify-cdc &&
  make verify-ingestion &&
  make verify-dbt &&
  make verify-airflow &&
  make verify-superset
'
```

Browser checks (port-forward via SSH for now since there's no public route):
```bash
ssh -L 8088:localhost:8088 -L 8080:localhost:8080 -L 9080:localhost:9080 ubuntu@lmis-dev.health.gov.mw
```
- Superset: <http://localhost:8088> (`admin` / `<from .env.reporting-stack>`)
- Airflow:  <http://localhost:8080> (`admin` / `<from .env.reporting-stack>`)
- Kafka UI: <http://localhost:9080>

Once browsers are happy: open one of the migrated Malawi dashboards in
Superset and confirm at least one row of data.

---

## Step 7 — Decommission old reporting host

Once the new stack is verified on `lmis-dev`:

1. Stop the legacy reporting compose on `reporting-lmis-dev.health.gov.mw`:
   ```
   # via the Jenkins dev_reporting_env job, or manually:
   ssh ubuntu@reporting-lmis-dev.health.gov.mw \
     'cd /path/to/mw-distro/reporting && docker-compose down -v'
   ```
2. Disable the legacy `dev_reporting_env` Jenkins job (don't delete — keeps
   the historical config visible for reference).
3. Leave the EC2 instance running for ~1 sprint as a safety net, then
   terminate.

---

## Follow-ups (after a green first deploy)

- **OAuth / Superset embedding from OLMIS UI.** The OLMIS `.env` has
  `SUPERSET_URL=https://reporting-lmis-dev.health.gov.mw` and
  `SUPERSET_REDIRECT_URI=...`. While the old host is up, those still work.
  After decommissioning, options:
  - Swing DNS for `reporting-lmis-dev.health.gov.mw` to the `lmis-dev` IP
    and add nginx routing to forward Superset traffic by `Host` header.
    Existing OAuth URIs keep working.
  - Or change the env to point at a new path/subdomain (requires updating
    the Superset OAuth client registration in OLMIS auth too).
- **HTTPS / public access.** The dev rollout exposes ports only via SSH
  tunnel. For permanent access, add an nginx vhost + ACM cert.
- **Connector SSL** (Step 2 above), once the pipeline is steady.
- **Backup discipline.** ClickHouse curated marts can be rebuilt from CDC
  raw + dbt — no separate backup needed. Superset metadata DB (dashboards,
  saved queries) should be added to RDS snapshot schedule or Postgres dump
  rotation.
- **Monitoring.** Hook into existing Scalyr / Prometheus (task 10 in the
  platform plan, post-MVP).

---

## Rollback

If anything breaks during/after the first deploy:

1. Stop the new stack: `ssh ubuntu@lmis-dev 'cd /opt/reporting-stack && make down'`.
2. Restart the legacy Nifi stack via the original `dev_reporting_env` Jenkins
   job (still enabled until Step 7).
3. Trigger the original `dev` Jenkins job (not the clone) — it's untouched
   and will deploy OLMIS without the reporting-stack additions.

The new Jenkins job clone, branches, and EC2 dir at `/opt/reporting-stack`
can sit idle until you're ready to retry.
