#!/usr/bin/env bash

export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="malawi-dev-nlb-a49a014fcf8d8b5c.elb.us-east-1.amazonaws.com:2376"
export DOCKER_CERT_PATH="${PWD}/../../credentials"

../shared/init_env.sh

/usr/local/bin/docker-compose pull

../shared/restart_or_restore.sh $1
