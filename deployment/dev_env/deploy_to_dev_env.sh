#!/usr/bin/env bash
#
# Deploys OpenLMIS Malawi (dev) to lmis-dev.health.gov.mw, then deploys the
# reporting-stack (openlmis-reporting) onto the SAME Docker host.
#
# Jenkins workspace layout assumed:
#   $WORKSPACE/
#     mw-openlmis-deployment/     (this repo)
#     malawi-configuration/        (private; cloned by Jenkins as "credentials")
#     openlmis-reporting/          (added to Jenkins job for reporting-stack)
#
# Inputs:
#   KEEP_OR_WIPE         env var (Jenkins choice param: "keep" | "wipe")
#   $1                   passed through to restart_or_restore.sh (unused by it,
#                        but kept for backward compatibility)
#
# Reporting-stack deploy is opt-out via SKIP_REPORTING_STACK=1 — useful when
# OLMIS-only redeploys are needed.

set -euo pipefail

# =============================================================================
# 1. OpenLMIS deploy (unchanged)
# =============================================================================
export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="lmis-dev.health.gov.mw:2376"
export DOCKER_CERT_PATH="${PWD}/../../credentials"

../shared/init_env.sh

/usr/local/bin/docker-compose pull

# $1 is vestigial (restart_or_restore.sh + restart.sh key off the KEEP_OR_WIPE
# env var, not this arg). Default it so `set -u` doesn't abort when Jenkins
# invokes the script with no positional argument.
../shared/restart_or_restore.sh "${1:-}"

# =============================================================================
# 2. Reporting-stack deploy on the same Docker host
# =============================================================================
# The reporting-stack compose uses local bind mounts (../scripts, ../airflow/dags,
# etc.), so it can't be deployed by pointing DOCKER_HOST at the remote daemon —
# the daemon would look for those paths on its own filesystem. We instead rsync
# the openlmis-reporting checkout to a fixed path on lmis-dev and run
# `make up && make setup` over SSH.

if [ "${SKIP_REPORTING_STACK:-0}" = "1" ]; then
  echo "SKIP_REPORTING_STACK=1 set — skipping reporting-stack deploy."
  exit 0
fi

# All Jenkins SCMs check out UNDER the workspace root:
#   mw-openlmis-deployment  -> workspace root (no subdir; this repo)
#   malawi-configuration    -> ./credentials  (subdir)
#   soldevelo-reporting-stack -> ./openlmis-reporting (subdir)
# $WORKSPACE is always set by Jenkins. The fallback derives the workspace root
# from this script's location (deployment/dev_env -> repo root == workspace root).
WORKSPACE_ROOT="${WORKSPACE:-$(cd "${PWD}/../.." && pwd)}"

REPORTING_REPO_LOCAL="${REPORTING_REPO_LOCAL:-${WORKSPACE_ROOT}/openlmis-reporting}"
REPORTING_REMOTE_HOST="${REPORTING_REMOTE_HOST:-lmis-dev.health.gov.mw}"
REPORTING_REMOTE_USER="${REPORTING_REMOTE_USER:-ubuntu}"
REPORTING_REMOTE_PATH="${REPORTING_REMOTE_PATH:-/opt/reporting-stack}"

CREDENTIALS_DIR="${WORKSPACE_ROOT}/credentials"
SSH_KEY="${CREDENTIALS_DIR}/id_rsa"
ENV_REPORTING="${CREDENTIALS_DIR}/.env.reporting-stack"

if [ ! -d "$REPORTING_REPO_LOCAL" ]; then
  echo "ERROR: openlmis-reporting checkout not found at $REPORTING_REPO_LOCAL" >&2
  echo "Add it as an SCM source in the Jenkins job." >&2
  exit 1
fi
if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY (expected in malawi-configuration)" >&2
  exit 1
fi
if [ ! -f "$ENV_REPORTING" ]; then
  echo "ERROR: .env.reporting-stack not found at $ENV_REPORTING" >&2
  echo "Add it to malawi-configuration (see deployment/dev_env/reporting-stack-setup.md)." >&2
  exit 1
fi

# SSH refuses to use keys with loose permissions; rsync inherits that.
chmod 600 "$SSH_KEY"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_TARGET="${REPORTING_REMOTE_USER}@${REPORTING_REMOTE_HOST}"

echo "=== Reporting-stack deploy ==="
echo "Target: ${SSH_TARGET}:${REPORTING_REMOTE_PATH}"
echo "Mode:   ${KEEP_OR_WIPE:-keep}"

# Stage .env on the Jenkins side so it gets rsync'd in.
cp "$ENV_REPORTING" "$REPORTING_REPO_LOCAL/.env"

# Ensure remote path exists and is owned by the deploy user.
ssh $SSH_OPTS "$SSH_TARGET" "sudo mkdir -p '$REPORTING_REMOTE_PATH' && sudo chown -R '$REPORTING_REMOTE_USER':'$REPORTING_REMOTE_USER' '$REPORTING_REMOTE_PATH'"

echo "Syncing repo..."
rsync -az --delete \
  -e "ssh $SSH_OPTS" \
  --exclude='.git/' \
  --exclude='.bootstrap/' \
  --exclude='.packages/' \
  --exclude='.dbt/' \
  "$REPORTING_REPO_LOCAL/" \
  "${SSH_TARGET}:${REPORTING_REMOTE_PATH}/"

echo "Running make up && make setup on remote host..."
ssh $SSH_OPTS "$SSH_TARGET" "KEEP_OR_WIPE='${KEEP_OR_WIPE:-keep}' REPORTING_REMOTE_PATH='$REPORTING_REMOTE_PATH' bash -s" <<'REMOTE'
set -euo pipefail
cd "$REPORTING_REMOTE_PATH"

# On 'wipe', the OLMIS DB was restored from snapshot — the replication slot is
# gone and CDC offsets are stale, so reset the reporting-stack volumes and let
# Debezium re-snapshot.
if [ "${KEEP_OR_WIPE:-keep}" = "wipe" ]; then
  echo "KEEP_OR_WIPE=wipe — resetting reporting-stack volumes for fresh snapshot."
  make reset || true
fi

# --- dbt-directory perms + AIRFLOW_DOCKER_GID alignment ---------------------
# The Airflow scheduler runs as uid 50000 with group_add: ["$AIRFLOW_DOCKER_GID"]
# so it can talk to /var/run/docker.sock. The same supplementary group is what
# lets it (and host-shell operators running as `ubuntu`) write into the dbt
# directory — specifically packages.yml, which scripts/dbt/run.sh regenerates.
#
# Two things have to be in sync:
#   1. .env must carry the host's docker-group GID so compose's group_add
#      receives the right value. We auto-detect from /var/run/docker.sock here
#      so the deploy survives host rebuilds (the GID can shift between
#      installs) without hand-editing malawi-configuration.
#   2. The dbt/ directory must be group-owned by that GID and group-writable
#      so a freshly rsync'd tree (default 0644 ubuntu:ubuntu) doesn't lock
#      out the airflow uid the first time the DAG runs.
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
echo "Host docker.sock gid: $DOCKER_GID — applying to .env and dbt/ perms."

if grep -q '^AIRFLOW_DOCKER_GID=' .env; then
  sed -i "s|^AIRFLOW_DOCKER_GID=.*|AIRFLOW_DOCKER_GID=$DOCKER_GID|" .env
else
  echo "AIRFLOW_DOCKER_GID=$DOCKER_GID" >> .env
fi

chgrp -R "$DOCKER_GID" dbt
chmod -R g+rwX dbt

# --- Old-Docker workaround (REMOVE after the host's Docker/OS upgrade) -------
# Two issues with Docker 19.03 on this host are handled here:
#  1) BuildKit (compose's default builder) STRIPS the inherited Cmd/Entrypoint
#     from FROM+COPY images -> containers fail to start with "No command
#     specified". The classic builder (DOCKER_BUILDKIT=0) preserves it, so we
#     pre-build the custom images here; `make up` then reuses them (no rebuild).
#  2) The old libseccomp rejects the clone3 syscall. The Dockerfiles avoid it at
#     BUILD time (pip --progress-bar off; dbt on a bullseye base), so the classic
#     builder's old seccomp profile can build them. The seccomp-unconfined
#     compose overlay (+ DBT_DOCKER_SECCOMP in .env for the dbt run) covers
#     RUNTIME clone3.
echo "Pre-building custom images with the classic builder..."
for spec in kafka-connect:connect airflow:airflow superset:superset; do
  name="${spec%%:*}"; ctx="${spec##*:}"
  DOCKER_BUILDKIT=0 docker build -t "soldevelo-reporting-stack/${name}:latest" "$ctx"
done

export COMPOSE_OVERLAY=compose/docker-compose.seccomp-unconfined.yml
make up
# Git-mode packages: clone core + extensions to .packages/ so the connector
# and Superset importers (run by `make setup`) pick them up. dbt fetches its
# own copy via packages.yml. No-op in local mode (ANALYTICS_CORE_GIT_URL unset).
make package-fetch
make setup
REMOTE

echo "=== Done ==="
