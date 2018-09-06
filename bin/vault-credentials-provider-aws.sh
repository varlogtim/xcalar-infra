#!/bin/bash
#
#
#

# <-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------``````````````````````````````````````````````````````````````
# Vault gives us this format:
#
# {
#   "request_id": "9f8f7133-e341-5cfb-437f-f98646bf8d0f",
#   "lease_id": "aws/sts/deploy/d177f27b-9251-d261-956d-66b59428e79c",
#   "lease_duration": 3599,
#   "renewable": false,
#   "data": {
#     "access_key": "ASIAJEGZPHIMPZHJHIMQ",
#     "secret_key": "6chW+auMR53SFjrlhknxQohogp5xe7BFYuC8Kk23",
#     "security_token": "FQoDYXdzENj//////////wEaDNSxT0hN2kESqT1U/iL6AVrZFwmD0VWbNui+salnSrEuNTeVKwQacSzlQmlg4uCpuMSmhZb81GRn1mbkAE7iT/nr7TRJUoHBC75mMovLfjWBTNGfFSv8+Vq4plbHbKbigKznucSic+9o/TmzvxUtjvjEmHqYOQWPbvix6krSWVxbinL29AVpgV4A6hUro0FuGaQNGfjAPrb3D0xYgDt2UXV65v0ufiRcS0Ql4o8Rtepx9p8QUIZnMcbVlYWO+//Fh1A/SqBJQIMWIppZrtwHfjnNHqlqQLGI3Nz6rPCttTbhaZ7FJMW6TJ3jWrsQXCo68zdarVeDsjjVeTqsppr7jOpBzMT2+Ment9EopP6t1gU="
#   },
#   "warnings": null
# }
#
# Aws wants this (via https://docs.aws.amazon.com/cli/latest/topic/config-vars.html#sourcing-credentials-from-external-processes):
#
# {
#   "Version": 1,
#   "AccessKeyId": "",
#   "SecretAccessKey": "",
#   "SessionToken": "",
#   "Expiration": ""
# }

FILE=""
TTL=12h
ACCOUNT="aws-xcalar"
TYPE="sts"
ROLE="poweruser"
CLEAR=false
EXPORT=false
INSTALL=false

say() {
    echo >&2 "$1"
}

die() {
    say "ERROR: $1"
    exit ${2:-1}
}

if [[ $OSTYPE =~ darwin ]]; then
    please_install() {
        die "You need to install $1. Try 'brew install $1'"
    }
    date() {
        gdate "$@"
    }
else
    please_install() {
        die "You need to install $1. Try 'apt-get install $1' or 'yum install --enablerepo='xcalar-*' $1'"
    }
fi

vault_status() {
    local status
    if status="$(set -o pipefail; vault status -format=json | jq -r .sealed)" && [ "$status" = false ]; then
        return 0
    fi
    return 1
}

vault_install_credential_helper() {
    vault_sanity
    aws configure set default.region us-west-2
    aws configure set default.s3.signature_version s3v4
    aws configure set default.s3.addressing_style path

    touch ~/.aws/credentials
    sed -i'' '/^\[vault\]/,+1 d' ~/.aws/credentials
    cat >> ~/.aws/credentials <<EOF

[vault]
credential_process = $(readlink -f ${BASH_SOURCE[0]}) --path $AWSPATH
EOF
    echo "Done. Please use 'aws --profile vault <cmd>'. To avoid having to type --profile" >&2
    echo "on every command, add 'export AWS_PROFILE=vault' to your ~/.bashrc" >&2

}

vault_sanity () {
    local -a aws_version
    aws_version=($(aws --version 2>&1 | sed -E 's@^aws-cli/([0-9\.]+).*$@\1@g' | tr  . ' '))
    if [ ${aws_version[1]} -lt 15 ]; then
        die "awscli needs to be version 15.40 or higher. Use virtualenv and pip install -U awscli."
    fi
    local progs="jq vault curl" prog
    for prog in $progs; do
        if ! command -v $prog >/dev/null; then
            please_install $prog
        fi
    done
    if [[ $OSTYPE =~ darwin ]] && ! command -v gdate >/dev/null; then
        please_install coreutils
    fi
    if [ -z "$VAULT_ADDR" ]; then
        die "VAULT_ADDR not set. Please set 'export VAULT_ADDR=https://yourvaultserver' to your ~/.profile or ~/.bash_profile"
    fi
    if ! curl -o /dev/null -s "$VAULT_ADDR"; then
        die "Failed to connect to VAULT_ADDR=$VAULT_ADDR in a secure fashion. Please check http://wiki.int.xcalar.com/mediawiki/index.php/Xcalar_Root_CA"
    fi
    if ! vault_status; then
        die "Failed to get 'vault status', or vault is sealed"
    fi
    if ! AUTH_TOKEN=$(set -o pipefail; vault read -format=json -field=data auth/token/lookup-self | jq -r .id); then
        die "Failed to look you up. Are you logged into vault? Try 'vault login -method=ldap username=jdoe'. Your username is your LDAP username (usually the part before @xcalar.com in your email)"
    fi
}

iso2unix() {
    date -u -d "$1" +%s
}

unix2iso() {
    date -u -d "$1" +%FT%T.000Z
}

vault2aws() {
    local ttl expiration
    if ! ttl="$(jq -r .lease_duration "$1")";  then
        say "Failed to get lease_duration from $1"
        ttl=''
    fi
    if [ -z "$ttl" ] || [ "${ttl:0:1}" = 0 ]; then
        jq -r '
        {
            Version: 1,
            AccessKeyId: .data.access_key,
            SecretAccessKey: .data.secret_key,
            SessionToken: .data.security_token
        }' $1
    else
        expiration="$(unix2iso "$ttl seconds")"
        jq -r '
        {
            Version: 1,
            AccessKeyId: .data.access_key,
            SecretAccessKey: .data.secret_key,
            SessionToken: .data.security_token,
            Expiration: "'$expiration'"
        }' $1
    fi
}

usage() {
    cat <<EOF >&2
    usage: $0 [--account ACCOUNT] [--role ROLE] [--type TYPE] [--path PATH] [--ttl TTL] [--export] [--profile <named aws profile>] [--install]
EOF
    die "$1"
}

main() {
    while [ $# -gt 0 ]; do
        local cmd="$1"
        case "$cmd" in
            -h|--help) usage;;
            -i|--install) INSTALL=true; shift ;;
            --check) vault_sanity;;
            --account) ACCOUNT="$2"; shift 2;;
            --role) ROLE="$2"; shift 2;;
            --type) TYPE="$2"; shift 2;;
            -c|--clear) CLEAR=true; shift;;
            -f|--file) FILE="$2";shift 2;;
            --path) AWSPATH="$2"; shift 2;;
            --export) EXPORT=true; shift;;
            --profile) PROFILE="$2"; shift 2;;
            --ttl) TTL="$2"; shift 2;;
            --) shift; break;;
            -*) usage "Unknown argument $cmd"; exit 1;;
            *) break;;
        esac
    done
    if [ -z "$AWSPATH" ]; then
        AWSPATH="$ACCOUNT/$TYPE/$ROLE"
    fi
    if $INSTALL; then
        vault_install_credential_helper
        exit $?
    fi
    VAULTCACHE="$HOME/.aws/cache/${AWSPATH}.json"
    AWSCACHE="$HOME/.aws/cache/${AWSPATH}-aws.json"
    FILE="$VAULTCACHE"
    if $CLEAR; then
        say "Clearing cached credentials for $AWSPATH .."
        rm -f "$VAULTCACHE" "$AWSCACHE"
        exit $?
    fi
    NOW=$(date +%s)

    mkdir -m 0700 -p $(dirname $VAULTCACHE)
    if [ -r "$AWSCACHE" ]; then
        EXPIRATION=$(jq -r .Expiration < $AWSCACHE)
        EXPIRATION_TS=$(iso2unix $EXPIRATION)
        if [[ $((EXPIRATION_TS - NOW)) -gt 300 ]]; then
            if $EXPORT; then
                echo "export AWS_ACCESS_KEY_ID=\"$(jq -r .data.access_key $FILE)\""
                echo "export AWS_SECRET_ACCESS_KEY=\"$(jq -r .data.secret_key $FILE)\""
                echo "export AWS_SESSION_TOKEN=\"$(jq -r .data.security_token $FILE)\""
            elif [ -n "$PROFILE" ]; then
                echo "[$PROFILE]"
                echo aws_access_key_id = $(jq -r .data.access_key $FILE)
                echo aws_secret_access_key = $(jq -r .data.secret_key $FILE)
                echo aws_session_token = $(jq -r .data.security_token $FILE)
            else
                cat $AWSCACHE
            fi
            # refresh token?
            exit 0
        fi
    fi

    TMPDIR=$HOME/.aws/tmp
    mkdir -m 0700 -p $TMPDIR
    TMP=$(mktemp -t vaultXXXXXX.json)
    case "$AWSPATH" in
        */sts/*) vault write -format=json "$AWSPATH" ttl=$TTL > "$TMP";;
        */creds/*) vault read -format=json "$AWSPATH"  ttl=$TTL > "$TMP";;
        *) die "Unknown type of path $AWSPATH";;
    esac
    if [ $? -ne 0 ]; then
        echo >&2 "ERROR: Failed to get valid vault creds for $AWSPATH"
        echo >&2 "Check ~/.vault-token, VAULT_TOKEN and $TMP"
        echo >&2 "VAULT_ADDR=$VAULT_ADDR"
        exit 1
    fi
    mv "$TMP" "$FILE"
    SEC="$(jq -r .lease_duration "$FILE")"
    EXPIRATION="$(unix2iso "$SEC seconds")"

    if $EXPORT; then
        echo "export AWS_ACCESS_KEY_ID=\"$(jq -r .data.access_key $FILE)\""
        echo "export AWS_SECRET_ACCESS_KEY=\"$(jq -r .data.secret_key $FILE)\""
        echo "export AWS_SESSION_TOKEN=\"$(jq -r .data.security_token $FILE)\""
    elif [ -n "$PROFILE" ]; then
        echo "[$PROFILE]"
        echo aws_access_key_id = $(jq -r .data.access_key $FILE)
        echo aws_secret_access_key = $(jq -r .data.secret_key $FILE)
        echo aws_session_token = $(jq -r .data.security_token $FILE)
    else
        #vault2aws "$EXPIRATION" < "$FILE" | tee "$AWSCACHE"
        vault2aws "$FILE" | tee "$AWSCACHE"
    fi
}

main "$@"
