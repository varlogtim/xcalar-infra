#!/bin/bash

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDUP="$(cd "${DIR}/.." && pwd)"

DRYRUN=false
EMAIL="${EMAIL:-devaccounts@xcalar.com}"
LE_ENDPOINT=https://acme-v02.api.letsencrypt.org/directory
LE_DIR="/etc/letsencrypt"
LE_ACCOUNTS=${CDUP}/letsencrypt-accounts-shared
AWS_ACCOUNT=aws-xcalar

usage() {
    echo >&2 "usage: $0 [--domain (default: $DOMAIN)] [--email (default: $EMAIL)] [--dryrun]"
    echo >&2 "  Renews LetsEncrypt certificates via certbot"
    echo >&2 ""
    exit 1
}

DOMAIN_ARGS=""
while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        --aws-account)
            AWS_ACCOUNT="$1"
            shift
            ;;
        -d | --domain)
            if [ -z "$DOMAIN" ]; then
                DOMAIN="$1"
            fi
            DOMAIN_ARGS="$DOMAIN_ARGS -d $1"
            shift
            ;;
        -e | --email)
            EMAIL="$1"
            shift
            ;;
        -n | --dryrun | --dry-run)
            DRYRUN=true
            LE_ENDPOINT=https://acme-staging-v02.api.letsencrypt.org/directory
            LE_DIR="/etc/letsencrypt-stage"
            ;;
        -i | --image)
            IMAGE="$1"
            shift
            ;;
        -h | --help) usage ;;
        *)
            echo >&2 "ERROR: Unknown argument $cmd"
            exit 2
            ;;
    esac
done

DEXT=${DOMAIN:0:1}
if [ "${DEXT}" = '*' ]; then
    DOMAIN=${DOMAIN#*.}
    DOMAIN_ARGS='-d '${DOMAIN}' -d *.'${DOMAIN}
fi

if [ -z "$IMAGE" ]; then
    case "$DOMAIN" in
        *.demo.xcalar.cloud | demo.xcalar.cloud) IMAGE=certbot/dns-route53; AWS_ACCOUNT=aws-xcalar-trials;;
        *.test.xcalar.cloud | test.xcalar.cloud) IMAGE=certbot/dns-route53 ; AWS_ACCOUNT=aws-test;;
        *.xcalar.cloud | xcalar.cloud) IMAGE=certbot/dns-route53 ; AWS_ACCOUNT=aws-pegasus;;
        *.xcalar.rocks | xcalar.rocks) IMAGE=certbot/dns-route53 ;;
        *.xcalar.io | xcalar.io) IMAGE=certbot/dns-google ;;
        *.xcalar.com | xcalar.com) IMAGE=certbot/dns-google ;;
        *)
            IMAGE=certbot/certbot
            echo >&2 "Unrecognized domain: ${DOMAIN}. Using manual verification."
            ;;
    esac
fi

TMP=$(mktemp -t dns.XXXXXX)
# shellcheck disable=SC2046
trap "rm -f $TMP" EXIT

if ! test -w /var/run/docker.sock; then
    DOCKER='sudo docker'
else
    DOCKER=docker
fi

$DOCKER pull $IMAGE

DOCKER_FLAGS="-it --rm --name certbot -v $LE_DIR:/etc/letsencrypt -v $LE_ACCOUNTS:/etc/letsencrypt/accounts -v /var/lib/letsencrypt:/var/lib/letsencrypt --dns 8.8.8.8 --dns 8.8.4.4"

if [[ $IMAGE == certbot/dns-google ]]; then
    (
        vault kv get -field=data secret/service_accounts/gcp/google-dnsadmin >> $TMP
        set -x
        $DOCKER run $DOCKER_FLAGS \
            -v "$(readlink -f $TMP):/etc/gdns.json:ro" \
            $IMAGE certonly --dns-google-credentials /etc/gdns.json \
            --server $LE_ENDPOINT -m ${EMAIL} --agree-tos $DOMAIN_ARGS

    )
elif [[ $IMAGE == certbot/dns-route53 ]]; then
    (
        set +x
        if [ -z "$AWS_SESSION_TOKEN" ]; then
            eval $(vault-aws-credentials-provider.sh --account $AWS_ACCOUNT --export-env --ttl 900) || exit 1
        fi
        aws sts get-caller-identity || true
        (set -x; sleep 20)
        set -x
        $DOCKER run $DOCKER_FLAGS \
            -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
            $IMAGE certonly --dns-route53 --dns-route53-propagation-seconds 60 \
            --server $LE_ENDPOINT -m ${EMAIL} --agree-tos $DOMAIN_ARGS
    )
else
        $DOCKER run $DOCKER_FLAGS \
            $IMAGE certonly \
            --preferred-challenges "dns-01" \
            --server $LE_ENDPOINT -m ${EMAIL} --agree-tos $DOMAIN_ARGS
fi
if [ $? -ne 0 ]; then
    exit 1
fi

echo >&2 "The key is in ${LE_DIR}/live/${DOMAIN}/privkey.pem and the certificate is in ${LE_DIR}/live/${DOMAIN}/fullchain.pem"

if $DRYRUN; then
    $DOCKER run --rm -v ${LE_DIR}:${LE_DIR}:ro busybox cat ${LE_DIR}/live/${DOMAIN}/privkey.pem | tee privkey.pem
    $DOCKER run --rm -v ${LE_DIR}:${LE_DIR}:ro busybox cat ${LE_DIR}/live/${DOMAIN}/fullchain.pem | tee fullchain.pem
else
    echo >&2 "Storing key and cert into vault: secret/certs/${DOMAIN}/cert.key and cert.crt"

    $DOCKER run --rm -v ${LE_DIR}:${LE_DIR}:ro busybox cat ${LE_DIR}/live/${DOMAIN}/privkey.pem | vault kv put secret/certs/${DOMAIN}/cert.key data=-
    $DOCKER run --rm -v ${LE_DIR}:${LE_DIR}:ro busybox cat ${LE_DIR}/live/${DOMAIN}/fullchain.pem | vault kv put secret/certs/${DOMAIN}/cert.crt data=-

    vault kv get -field=data secret/certs/${DOMAIN}/cert.key > $DOMAIN.key
    vault kv get -field=data secret/certs/${DOMAIN}/cert.crt > $DOMAIN.crt
    echo >&2 "# Stored certificates:"
    echo "crt: $(pwd)/${DOMAIN}.crt"
    echo "key: $(pwd)/${DOMAIN}.key"
fi
