#!/bin/bash
JENKINS_URL="${JENKINS_URL:-https://jenkins.int.xcalar.com/}"

JENKINS_HOST="${JENKINS_URL#https://}"
JENKINS_HOST="${JENKINS_HOST%/}"
PORT="${PORT:-22022}"

test $# -gt 0 || set -- help

exec ssh -oPort=${PORT} ${JENKINS_HOST} "$@"
