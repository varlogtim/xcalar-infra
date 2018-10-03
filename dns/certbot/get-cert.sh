#!/bin/bash
#
# prints current CRT and KEY for given domain

set -e
set -o pipefail

. infra-sh-lib

DOMAIN=${1:-xcalar.com}

while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        -d | --domain) DOMAIN="$1"; shift;;
        *) echo >&2 "ERROR: Unknown parameter $cmd"; exit 1;;
    esac
done

[ -n "$DOMAIN" ] || die "Need to specify DOMAIN via environment or --domain"

vault kv get -field=data secret/certs/${DOMAIN}/cert.crt | tee ${DOMAIN}.crt
vault kv get -field=data secret/certs/${DOMAIN}/cert.key | tee ${DOMAIN}.key
