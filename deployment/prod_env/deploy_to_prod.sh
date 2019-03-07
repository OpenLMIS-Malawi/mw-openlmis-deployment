#!/usr/bin/env bash

export DOCKER_TLS_VERIFY="0"
export DOCKER_HOST="malawi-prod-elb-270164566.eu-west-1.elb.amazonaws.com:2376"
export DOCKER_CERT_PATH="${PWD}/../../credentials"

../shared/init_env.sh

../shared/pull_images.sh $1

../shared/restart.sh $1
