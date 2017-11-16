#!/usr/bin/env bash

if [ "$KEEP_OR_WIPE" == "wipe" ]; then
    echo "Restoring database from the latest snapshot"
    cp ../../credentials/.env-restore ../shared/restore/.env-restore

    /usr/local/bin/docker-compose down -v
    /usr/local/bin/docker-compose -f ../shared/restore/docker-compose.yml run rds-restore
    /usr/local/bin/docker-compose up --build --force-recreate -d
else
    ../shared/restart.sh $1
fi
