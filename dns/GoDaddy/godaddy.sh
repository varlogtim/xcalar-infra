#!/bin/bash
set -e

TYPE="${1?Must specify type A or CNAME}"
NAME="${2?Must specify name}"
IP="${3?Must specify IP or CNAME}"
TTL="${4:-900}"

if [ "$TYPE" != A ] && [ "$TYPE" != CNAME ]; then
    echo >&2 "Must specify type A or CNAME!"
    exit 1
fi

set +x
set -o pipefail
eval $(pass xcalar.com/GoDaddyAPI)
test -n "$GODADDY_KEY" && test -n "$GODADDY_SECRET" || { \
    echo >&2 "Need to specify GODADDY_KEY and GODADDY_SECRET"
    exit 1
}
TMP="$(mktemp /tmp/godaddyXXXX.json)"
INPUT="$(mktemp /tmp/godaddyXXXX.json)"
(
cat <<EOF
[{"type": "A", "name": "${NAME}","data":"${IP}","ttl":${TTL}}]
EOF
) | jq -r . > $INPUT
# See https://developer.godaddy.com/doc#!/_v1_domains/recordAdd
curl -sL \
     -X PATCH \
     -H "Authorization: sso-key ${GODADDY_KEY}:${GODADDY_SECRET}" \
     -H 'Content-Type: application/json' \
     https://api.godaddy.com/v1/domains/${DOMAIN}/records/ \
     -d @$INPUT | jq -r . > $TMP
if [ $? -ne 0 ] || [ "$(jq -r .code < $TMP)" != null ]; then
    jq -r . < $INPUT
    jq -r . < $TMP
    echo >&2 "ERROR: There was an error with the request. See $INPUT and $TMP"
    exit 1
fi
rm -f $TMP $INPUT
exit 0
