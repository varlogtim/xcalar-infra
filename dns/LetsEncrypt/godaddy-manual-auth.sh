#!/bin/bash
#
# This script is called by certbot-auto to handle the DNS
# TXT record registration it uses to verify domain ownership
#

set -e

DOMAIN=$(expr match "$CERTBOT_DOMAIN" '.*\.\(.*\..*\)')
NAME="_acme-challenge.$CERTBOT_DOMAIN"
DATA="$CERTBOT_VALIDATION"
TYPE=TXT
TTL=600

test -n "$GODADDY_KEY" && test -n "$GODADDY_SECRET" && test -n "$DOMAIN" || { \
    echo >&2 "Need to specify GODADDY_KEY, GODADDY_SECRET and DOMAIN"
    exit 1
}
TMP="$(mktemp /tmp/godaddyXXXX-out.json)"
INPUT="$(mktemp /tmp/godaddyXXXX-in.json)"
(
cat <<EOF
[{"type": "${TYPE}", "name": "${NAME}","data":"${DATA}","ttl":${TTL}}]
EOF
) | jq -r . | tee $INPUT
# See https://developer.godaddy.com/doc#!/_v1_domains/recordAdd
# PUT method will create or update. PATCH only creates. There is no
# DELETE method so you need to go into the UI after the fact to clean
# out old TXT records starting with _acme-xxx
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
sleep 30
exit 0
