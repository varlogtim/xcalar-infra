#!/bin/bash
#
# Update a GoDaddy DNS entry. Pass in a line formatted like a ZONE entry:
#
#
# ./godaddy.sh  www  3600 IN  A   1.2.3.4
#
# HIGHLY recommend backing up all entries first via ./godaddy-backup.py
#
set -e

NAME="${1?Must specify name}"
TTL="${2:-900}"
IN=${3:-IN}
TYPE="${4?Must specify type A, CNAME or TXT}"
DATA="${5?Must specify value to set}"

if [ "$TYPE" != A ] && [ "$TYPE" != CNAME ] && [ "$TYPE" != TXT ] && [ "$TYPE" != NS ]; then
    echo >&2 "Must specify type A, CNAME or TXT!"
    exit 1
fi

set +x
set -o pipefail
test -n "$GODADDY_KEY" && test -n "$GODADDY_SECRET" && test -n "$DOMAIN" || eval $(pass xcalar.com/GoDaddyAPI)
test -n "$GODADDY_KEY" && test -n "$GODADDY_SECRET" && test -n "$DOMAIN" || { \
    echo >&2 "Need to specify GODADDY_KEY, GODADDY_SECRET and DOMAIN"
    exit 1
}
if [ "$IN" != IN ]; then
    echo >&2 "Don't know what to do with IN=$IN type"
    exit 1
fi
TMP="$(mktemp /tmp/godaddyXXXX-out.json)"
INPUT="$(mktemp /tmp/godaddyXXXX-in.json)"
(
cat <<EOF
[{"type": "${TYPE}", "name": "${NAME}","data":"${DATA}","ttl":${TTL}}]
EOF
) | jq -r . | tee $INPUT
# See https://developer.godaddy.com/doc#!/_v1_domains/recordAdd
curl -sL \
     -X PUT \
     -H "Authorization: sso-key ${GODADDY_KEY}:${GODADDY_SECRET}" \
     -H 'Content-Type: application/json' \
     https://api.godaddy.com/v1/domains/${DOMAIN}/records/${TYPE}/${NAME} \
     -d @$INPUT | jq -r . > $TMP
if [ $? -ne 0 ] || [ "$(jq -r .code < $TMP)" != null ]; then
    jq -r . < $INPUT
    jq -r . < $TMP
    echo >&2 "ERROR: There was an error with the request. See $INPUT and $TMP"
    exit 1
fi
rm -f $TMP $INPUT
exit 0
