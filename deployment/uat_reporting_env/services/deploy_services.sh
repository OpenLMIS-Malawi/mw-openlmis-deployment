#!/usr/bin/env bash

export DOCKER_TLS_VERIFY="1"
export COMPOSE_TLS_VERSION=TLSv1_2
export DOCKER_HOST="malawi-uat-reporting-elb-1801856141.eu-west-1.elb.amazonaws.com:2376"
export DOCKER_CERT_PATH="${PWD}/../../../credentials"
export DOCKER_COMPOSE_BIN=/usr/local/bin/docker-compose

export REPORTING_DIR_NAME=reporting

reportingRepo=$1

cd "$reportingRepo/$REPORTING_DIR_NAME"
$DOCKER_COMPOSE_BIN kill
$DOCKER_COMPOSE_BIN down -v
$DOCKER_COMPOSE_BIN up --build --force-recreate -d
