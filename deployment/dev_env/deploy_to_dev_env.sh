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

../shared/restart_or_restore.sh $1

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

REPORTING_REPO_LOCAL="${REPORTING_REPO_LOCAL:-${PWD}/../../../openlmis-reporting}"
REPORTING_REMOTE_HOST="${REPORTING_REMOTE_HOST:-lmis-dev.health.gov.mw}"
REPORTING_REMOTE_USER="${REPORTING_REMOTE_USER:-ubuntu}"
REPORTING_REMOTE_PATH="${REPORTING_REMOTE_PATH:-/opt/reporting-stack}"

CREDENTIALS_DIR="${PWD}/../../credentials"
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

make up
make setup
REMOTE

echo "=== Done ==="
