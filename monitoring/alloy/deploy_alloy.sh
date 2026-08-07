#!/usr/bin/env bash
# Deploy the Grafana Alloy monitoring agent to an environment's Docker host.
# Mirrors deployment/*/deploy_to_*_env.sh: per-environment config + secrets come
# from the malawi-configuration checkout (Jenkins puts it in ../../credentials).
# Run from a checkout with `credentials/` alongside (see the Jenkins job / README).
set -e

cd "$(dirname "$0")"

# per-environment config + secrets (INGEST_TOKEN, DOCKER_HOST, labels, network)
cp ../../credentials/alloy.env ./.env

# load DOCKER_HOST (and the rest) so docker-compose targets the right daemon
set -a
. ./.env
set +a

export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH="$(cd ../../credentials && pwd)"

# --build bakes config.alloy into the image and sends it to the remote daemon
/usr/local/bin/docker-compose up -d --build
