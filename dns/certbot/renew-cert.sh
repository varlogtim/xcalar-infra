#!/bin/bash

set -e

DOMAIN=${DOMAIN:-xcalar.com}
EMAIL="${EMAIL:-devaccounts@xcalar.com}"
LE_ENDPOINT=https://acme-v02.api.letsencrypt.org/directory
IMAGE=certbot/dns-google

usage() {
    echo >&2 "usage: $0 [--domain (default: $DOMAIN)] [--email (default: $EMAIL)] [--dryrun]"
    echo >&2 "  Renews LetsEncrypt certificates via certbot"
    echo >&2 ""
    exit 1
}

while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        -d | --domain) DOMAIN="$1"; shift;;
        -e | --email) EMAIL="$1"; shift;;
        -n | --dryrun | --dry-run) LE_ENDPOINT=https://acme-staging-v02.api.letsencrypt.org/directory;;
        -h|--help) usage;;
        *) echo >&2 "ERROR: Unknown argument $cmd"; exit 2;;
    esac
done

case "$DOMAIN" in
    *.xcalar.cloud | xcalar.cloud) IMAGE=certbot/dns-route53;;
    *.xcalar.rocks | xcalar.rocks) IMAGE=certbot/dns-route53;;
    *.xcalar.io    | xcalar.io) IMAGE=certbot/dns-google;;
    *.xcalar.com   | xcalar.com) IMAGE=certbot/dns-google;;
    *) echo >&2 "Unrecognized domain: ${DOMAIN}"; exit 1;;
esac

TMP=$(mktemp -t dns.XXXXXX)
trap "rm -f $TMP" EXIT

if [[ $IMAGE = certbot/dns-google ]]; then
    (
    vault kv get -field=data secret/service_accounts/gcp/google-dnsadmin >> $TMP
    set -x
    docker run -it --rm --name certbot \
                -v "/etc/letsencrypt:/etc/letsencrypt" \
                -v "/var/lib/letsencrypt:/var/lib/letsencrypt" \
                -v "$(readlink -f $TMP):/etc/gdns.json:ro" \
                $IMAGE certonly --dns-google-credentials /etc/gdns.json \
                --server $LE_ENDPOINT -m ${EMAIL} --agree-tos \
                -d "*.${DOMAIN}" -d $DOMAIN
    )
elif [[ $IMAGE = certbot/dns-route53 ]]; then
    (
    eval $(vault-aws-credentials-provider.sh --export-env --ttl 15m) || exit 1
    set -x
    docker run -it --rm --name certbot \
                -v "/etc/letsencrypt:/etc/letsencrypt" \
                -v "/var/lib/letsencrypt:/var/lib/letsencrypt" \
                -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
                $IMAGE certonly --dns-route53 --dns-route53-propagation-seconds 30 \
                --server $LE_ENDPOINT -m ${EMAIL} --agree-tos \
                -d "*.${DOMAIN}" -d $DOMAIN
    )
fi

echo >&2 "The key is in /etc/letsencrypt/live/${DOMAIN}/privkey.pem and the certificate is in /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

echo >&2 "Storing key and cert into vault: secret/certs/${DOMAIN}/cert.key and cert.crt"

sudo cat /etc/letsencrypt/live/${DOMAIN}/privkey.pem | vault kv put secret/certs/${DOMAIN}/cert.key data=-
sudo cat /etc/letsencrypt/live/${DOMAIN}/fullchain.pem | vault kv put secret/certs/${DOMAIN}/cert.crt data=-

vault kv get -field=data secret/certs/${DOMAIN}/cert.key
vault kv get -field=data secret/certs/${DOMAIN}/cert.crt