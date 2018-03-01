#!/bin/bash
# get the google credentials service principle

set -e

ARGS=()
DOMAINS=()
EMAIL=${EMAIL:-devaccounts@xcalar.com}
export GOPATH=${GOPATH:-$HOME/go}
export PATH=$PATH:${GOPATH}/bin

usage() {
    cat >&2 <<EOF
	usage: $0 [-h|--help] [--domains|-d <domains.txt>] [--dry-run|-n] [--activate] -- <lego args>"
	-d, --domains domains.txt			Load list of domains from domains.txt or specify a single domain
	-n, --dry-run						Use staging server
	example:
	$0  -d test.xcalar.com -d test2.xcalar.com --dry-run
	$0  -d test.xcalar.com
EOF
}

die() {
    echo >&2 "ERROR: $1"
    exit 1
}

while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        --help | -h)
            usage
            exit 1
            ;;
        --domains | -d)
            if [ -f "$1" ]; then
                DOMAINS+=($(cat "$1" | grep -Ev '^[#$]')) || die "Failed to read $1"
            else
                DOMAINS+=("$1")
            fi
            shift
            ;;
        --dry-run)
            ARGS+=(-s https://acme-staging.api.letsencrypt.org/directory)
            ;;
        --activate)
            ACTIVATE_ACCOUNT=1
            ;;
        --email|-e)
            EMAIL="$1"
            shift
            ;;
        --)
            break
            ;;
        -*)
            echo >&2 "Unknown argument: $cmd"
            exit 1
            ;;
    esac
done

TMPDIR="$(mktemp --tmpdir -d $(basename $0).XXXXXX)"
trap "rm -rf $TMPDIR" EXIT
if [ -z "$GCE_SERVICE_ACCOUNT_FILE" ]; then
    export GCE_SERVICE_ACCOUNT_FILE=$TMPDIR/key.json
    touch $GCE_SERVICE_ACCOUNT_FILE
    chmod 0600 $GCE_SERVICE_ACCOUNT_FILE
    vault read -format=json secret/google-dnsadmin | jq -r '.data.data|fromjson' | jq -r . >>$GCE_SERVICE_ACCOUNT_FILE
    if [ $? -ne 0 ]; then
        echo >&2 "Failed to get account credentials. Please set GCE_SERVICE_ACCOUNT_FILE or log in to vault"
        exit 1
    fi
fi

if [ -n "$ACTIVATE_ACCOUNT" ]; then
    CLIENT_EMAIL=$(jq -r .client_email <$GCE_SERVICE_ACCOUNT_FILE)
    ACCOUNT=$(gcloud config get-value account)
    gcloud auth activate-service-account --key-file=$GCE_SERVICE_ACCOUNT_FILE
    # Restore account
    gcloud config set account $ACCOUNT
fi

export GCE_PROJECT=angular-expanse-99923
export GCE_DOMAIN=xcalar.com

if [ "${#DOMAINS[@]}" -gt 0 ]; then
    for domain in "${DOMAINS[@]}"; do
        ARGS+=(-d $domain)
    done
fi

if ! command -v lego >/dev/null; then
    echo >&2 "Attempting to install github/xenolf/lego"
    go get -u github.com/xenolf/lego || exit 1
fi

lego --accept-tos --email "${EMAIL}" \
     --dns-resolvers="8.8.4.4:53" --dns-timeout 0 \
     --exclude http-01 --exclude tls-sni-01 \
     --dns gcloud "${ARGS[@]}" run
