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

## Step 0 — Prerequisites on `lmis-dev.health.gov.mw`

One-time setup on the OLMIS dev EC2 instance.

1. **Verify resources.** ~6 GB RAM and ~2 vCPU headroom on top of OLMIS:
   ```
   ssh ubuntu@lmis-dev.health.gov.mw 'free -h && nproc'
   ```
   If headroom is tight, bump the instance type before proceeding.

2. **Install Docker Compose v2 plugin.** The openlmis-reporting Makefile uses
   `docker compose` (v2 plugin), not `docker-compose` (v1 binary). Check:
   ```
   ssh ubuntu@lmis-dev.health.gov.mw 'docker compose version'
   ```
   If missing, install per the Docker docs. The existing OLMIS deploy keeps
   working with the v1 binary at `/usr/local/bin/docker-compose` — both can
   coexist.

3. **Verify `make` and `rsync` are installed:**
   ```
   ssh ubuntu@lmis-dev.health.gov.mw 'which make rsync git'
   ```

4. **Create the deploy target directory:**
   ```
   ssh ubuntu@lmis-dev.health.gov.mw 'sudo mkdir -p /opt/reporting-stack && sudo chown ubuntu:ubuntu /opt/reporting-stack'
   ```
   The deploy script does this automatically, but doing it manually first
   surfaces any sudo / permission issues outside a Jenkins run.

---

## Step 1 — RDS preflight (one-time)

The Malawi dev DB is RDS PG14, parameter group `postgres14`. Logical
replication is almost certainly off — none of the OLMIS services need it.

### 1a. Enable logical replication on the parameter group

In AWS console (or via CLI), edit parameter group `postgres14`:

| Parameter                          | Value | Notes                                              |
| ---------------------------------- | ----- | -------------------------------------------------- |
| `rds.logical_replication`          | `1`   | Required. Sets `wal_level=logical`.                |
| `max_wal_senders`                  | `10`  | PG14 default is 10; leave or raise.                |
| `max_replication_slots`            | `10`  | PG14 default is 10.                                |
| `max_logical_replication_workers`  | `4`   | Optional, only matters if many subscribers.        |
| `wal_sender_timeout`               | `0`   | Optional. Avoids killing slow connectors. Use cautiously — 0 disables timeout entirely. |

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

`mw_user` is the master user, so it already has `rds_superuser`. Confirm
it can replicate:
```
psql ... -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname='mw_user';"
```
If `rolreplication = f`, run:
```sql
ALTER ROLE mw_user WITH REPLICATION;
```
(Equivalent of `GRANT rds_replication TO mw_user` on RDS.)

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

## Step 2 — (Optional, recommended) Connector SSL

The current connector template at
`examples/olmis-analytics-core/connect/openlmis-postgres-cdc.json` does not
set `database.sslmode`. RDS accepts both SSL and non-SSL connections by
default, so the first deploy works without this change. To enforce TLS
in-transit, add to the template:

```json
"database.sslmode": "require",
```

(Use `verify-full` only if you mount the RDS CA bundle into the kafka-connect
container — leave that for a follow-up.)

Skip this step for the very first deploy if you want to minimize moving
parts. Come back to it once the pipeline is green.

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

1. In Jenkins, copy the `dev` job → name it e.g. `dev-with-reporting-stack`.
2. On the clone, add a **third SCM checkout** for `openlmis-reporting`:
   - Repository URL: the openlmis-reporting Git URL
   - Branch specifier: parameterize as `*/main` (or a feature branch while
     iterating)
   - Local subdirectory: leave default — should produce sibling layout
     with the other two repos
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
