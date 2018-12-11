#!/bin/bash
#
# prints current CRT and KEY for given domain

set -e
set -o pipefail

. infra-sh-lib

while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        -d | --domain) DOMAIN="${1#\*.}"; shift;;
        *) echo >&2 "ERROR: Unknown parameter $cmd"; exit 1;;
    esac
done

[ -n "$DOMAIN" ] || die "Need to specify DOMAIN via environment or --domain"

TMP=$(mktemp -t get-cert.XXXXXX)

trap "rm -f $TMP" EXIT

vault kv get -field=data -format=table secret/certs/${DOMAIN}/cert.crt > $TMP && mv $TMP ${DOMAIN}.crt || die "Unable to read vault. Are you logged in?"
vault kv get -field=data -format=table secret/certs/${DOMAIN}/cert.key > $TMP && mv $TMP ${DOMAIN}.key

echo >&2 "Saved certs:"
echo "${PWD}/${DOMAIN}.crt"
echo "${PWD}/${DOMAIN}.key"
