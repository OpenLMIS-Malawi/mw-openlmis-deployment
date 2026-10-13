# Reporting-stack deployment — Malawi UAT

Rollout of the openlmis-reporting platform to UAT, co-located with OpenLMIS on
`lmis-uat.health.gov.mw`, replacing the legacy Nifi-based stack on
`reporting-lmis-uat.health.gov.mw`.

UAT follows the **same procedure as dev** — see
[`../dev_env/reporting-stack-setup.md`](../dev_env/reporting-stack-setup.md)
for the full explanation of every step. This file only lists what is
different on UAT and the order to do things in.

---

## What is different from dev

| Item                     | dev                                   | UAT                                               |
| ------------------------ | ------------------------------------- | ------------------------------------------------- |
| OLMIS + reporting host   | `lmis-dev.health.gov.mw`              | `lmis-uat.health.gov.mw`                          |
| AWS region (RDS)         | `us-east-1`                           | `eu-west-1`                                       |
| RDS instance             | `malawi-dev-postgresql-db`            | the UAT instance (host in `spring.datasource.url` of the `uat` `.env`) |
| Deploy script            | `deployment/dev_env/deploy_to_dev_env.sh` | `deployment/uat_env/deploy_to_uat_env.sh`     |
| Config branch            | `malawi-configuration` `master`       | `malawi-configuration` `uat`                      |
| Legacy reporting host    | `reporting-lmis-dev.health.gov.mw`    | `reporting-lmis-uat.health.gov.mw`                |

UAT mirrors production sizing, so check capacity (Step 0a) rather than
assuming dev's numbers.

---

## Checklist

1. **Host prep on `lmis-uat`** — dev runbook Step 0 (0a–0g): capacity check,
   Compose v2 plugin, `ubuntu` in the `docker` group, 4 GB swap,
   `/opt/reporting-stack`. Note the host's Docker version in 0a: the deploy
   script keeps dev's Docker 19.03 workaround (classic builder pre-build +
   seccomp-unconfined overlay). It also works on newer Docker; it can be
   dropped once the UAT host is confirmed to run a modern engine.
2. **RDS preflight on the UAT instance** — dev runbook Step 1 (1a–1e):
   `rds.logical_replication=1` on the parameter group, **reboot the RDS
   instance (UAT downtime — announce it)**, `GRANT rds_replication`, create the
   publication / signal / heartbeat objects (1d SQL), security group check.
   Use `--region eu-west-1` in the AWS CLI commands.
3. **`malawi-configuration` (`uat` branch)** — add `.env.reporting-stack` for
   UAT (own generated secrets, UAT DB host/password), and in `.env` add
   `SUPERSET_ADMIN_USER` / `SUPERSET_ADMIN_PASSWORD` (must match
   `.env.reporting-stack`) and point `SUPERSET_URL` at the new stack, as on dev.
4. **Jenkins** — clone the existing UAT job (dev runbook Step 4): add the
   `soldevelo-reporting-stack` checkout into sub-directory
   `openlmis-reporting`, point both other SCMs at the feature branches, keep
   `KEEP_OR_WIPE`, optionally add `SKIP_REPORTING_STACK`.
   **Platform branch: `main`** (or whatever dev's job runs today) — **not**
   `dev-reporting-stack`, which the dev runbook names but which is behind
   `main` by the Malawi fixes (MW-1482 Country Map geojson / colour scheme /
   filter limits) and by the guest `can_explore_json` grant. Without that
   grant the embedded *District Stock-Out Rate (Map)* chart fails with
   "Access is Denied" in OpenLMIS while rendering fine inside Superset.
5. **First deploy** with `KEEP_OR_WIPE=keep`, then once, on the host:
   `cd /opt/reporting-stack && make initial-dbt-build` — the deploy script
   runs `make setup`, which does not build the curated marts; until this runs
   (or the Airflow `platform_refresh` DAG does) the dashboards are empty.
   Then verify (dev runbook Steps 5–6: `make verify-*`, Superset dashboards
   show data).
6. **Decommission** the legacy stack on `reporting-lmis-uat` and disable the
   `uat_reporting_env` Jenkins job (dev runbook Step 7) once the new stack is
   verified.

Rollback is the same as on dev: `make down` on `/opt/reporting-stack`, re-run
the legacy `uat_reporting_env` job and the original (un-cloned) UAT job.
