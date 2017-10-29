#!/bin/bash
#
# Call like this:
#  godaddy-renew.sh $(cat hosts/xcalar.com.txt)
#
# Must have API keys set! GODADDY_SECRET and GODADDY_KEY
#

test -n "$GODADDY_KEY" && test -n "$GODADDY_SECRET" && test -n "$DOMAIN" || { \
    echo >&2 "Need to specify GODADDY_KEY, GODADDY_SECRET and DOMAIN"
    exit 1
}

test $# -gt 0 || {
    echo >&2 "Need to specify some hosts!"
    exit 1
}

test -e certbot || git clone https://github.com/certbot/certbot

HOSTS=()
for HOST in "$@"; do
    HOSTS+=(-d $HOST)
done
echo ./certbot/certbot-auto certonly --manual --preferred-challenges dns --manual-auth-hook ./godaddy-add.sh --email devaccounts@xcalar.com ${HOSTS[*]}
