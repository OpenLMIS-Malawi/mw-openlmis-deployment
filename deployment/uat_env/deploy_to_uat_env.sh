#!/usr/bin/env bash

export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="lmis-uat.health.gov.mw:2376"
export DOCKER_CERT_PATH="${PWD}/../../credentials"

../shared/init_env.sh
cp ../../credentials/.env-restore ./.env-restore

../shared/pull_images.sh $1

if [ "$KEEP_OR_WIPE" == "wipe" ]; then
    echo "Restoring database from the latest snapshot"
    /usr/local/bin/docker-compose down
    docker-compose -f docker-compose-restore.yml run rds-restore
    unset spring_profiles_active
    /usr/local/bin/docker-compose up --build --force-recreate -d
else
    ../shared/restart.sh $1
fi
