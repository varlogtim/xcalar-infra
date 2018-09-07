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
TTL=8h
ACCOUNT="aws-xcalar"
TYPE="sts"
ROLE="poweruser"
CLEAR=false
EXPORT_ENV=false
EXPORT_PROFILE=false
INSTALL=false
PROFILE=vault

say() {
    echo >&2 "$1"
}

die() {
    say
    say "ERROR: $1"
    say
    exit ${2:-1}
}

if [[ $OSTYPE =~ darwin ]]; then
    please_install() {
        die "You need to install $1. Try 'brew install $1'"
    }
    date() {
        gdate "$@"
    }
    stat() {
        gstat "$@"
    }
else
    please_install() {
        die "You need to install $1. Try 'apt-get install $1' or 'yum install --enablerepo='xcalar-*' $1'"
    }
fi

usage() {
    cat << EOF >&2
    usage: $0 [--account ACCOUNT] [--type TYPE] [--role ROLE] [--path PATH] [--ttl TTL] [--install [--profile PROFILE]]
              [-c|--clear] [-e|--export-env] [--export-profile] [-f|--file FILE|-] [--check]

    --account  ACCOUNT   AWS Account to use (default $ACCOUNT)
    --type     TYPE      AWS Credentials type (default: $TYPE)
    --role     ROLE      AWS Role (default: $ROLE)
    --path     PATH      Complete ACCOUNT/TYPE/ROLE (default: $ACCOUNT/$TYPE/$ROLE)
    --ttl      TTL       TTL for token, min is 15m, max is 12h (default: $TTL)
    --install            Install this script into ~/.aws/credentials to automatically retrieve AWS keys for you
    --profile  PROFILE   AWS CLI Profile to populate from ~/.aws/credentials (default: $PROFILE)

    --check              Sanity check your installation
    -f|--file    FILE|-  Read existing credentials from FILE or - (stdin)
    -e|--export-env      Print out AWS environment variables for AWS access
    --export-profile     Print credentials format key
    -c|--clear           Clear all existing token
EOF
    die "$1"
}

vault_status() {
    local status
    if status="$(
        set -o pipefail
        vault status -format=json | jq -r .sealed
    )" && [ "$status" = false ]; then
        return 0
    fi
    return 1
}

aws_configure() {
    local value
    value="$(aws configure get $1)"
    if [ $? -eq 0 ] && [ -n "$value" ]; then
        return 0
    fi
    aws configure set $1 $2
}

vault_install_credential_helper() {
    vault_sanity
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"
    aws_configure default.region $AWS_DEFAULT_REGION
    aws_configure default.s3.signature_version s3v4
    aws_configure default.s3.addressing_style path

    touch ~/.aws/credentials
    sed -i.bak '/^\['$PROFILE'\]/,+2 d' ~/.aws/credentials
    cat >> ~/.aws/credentials << EOF
[$PROFILE]
credential_process = $(readlink -f ${BASH_SOURCE[0]}) --path $AWSPATH

EOF
    say "SUCCESS"
    if [ "$PROFILE" = default ]; then
        say "Use 'aws <cmd>' as normal"
    else
        say "Please use:"
        say "   aws --profile $PROFILE <cmd>"
        say ""
        say "To avoid having to add '--profile $PROFILE' to every awscli command, add:"
        say "   export AWS_PROFILE=$PROFILE"
        say ""
        say "to your ~/.bashrc or ~/.bash_aliases."
    fi
}

vault_sanity() {
    local -a aws_version
    aws_version=($(aws --version 2>&1 | sed -E 's@^aws-cli/([0-9\.]+).*$@\1@g' | tr . ' '))
    if [ ${aws_version[1]} -lt 15 ]; then
        die "awscli needs to be version 15.40 or higher. Use virtualenv and pip install -U awscli."
    fi
    local progs="jq vault curl" prog
    for prog in $progs; do
        if ! command -v $prog > /dev/null; then
            please_install $prog
        fi
    done
    if [[ $OSTYPE =~ darwin ]] && ! command -v gdate > /dev/null; then
        please_install coreutils
    fi
    if [ -z "$VAULT_ADDR" ]; then
        die "VAULT_ADDR not set. Please set 'export VAULT_ADDR=https://yourvaultserver' to your ~/.bashrc or ~/.bash_aliases"
    fi
    if ! curl -o /dev/null -s "$VAULT_ADDR"; then
        die "Failed to connect to VAULT_ADDR=$VAULT_ADDR in a secure fashion. Please check http://wiki.int.xcalar.com/mediawiki/index.php/Xcalar_Root_CA"
    fi
    if ! vault_status; then
        die "Failed to get 'vault status', or vault is sealed"
    fi
    if ! AUTH_TOKEN=$(
        set -o pipefail
        vault read -format=json -field=data auth/token/lookup-self | jq -r .id
    ); then
        die "Failed to look you up. Are you logged into vault? Try 'vault login -method=ldap username=jdoe'. Your username is your LDAP username (usually the part before @xcalar.com in your email)"
    fi
}

iso2unix() {
    date -u -d "$1" +%s
}

unix2iso() {
    date -u -d "$1" +%FT%T.000Z
}

expiration_ts() {
    local file_time=$(stat -c %Y "$1")
    local expiration=$((file_time + $2))
    unix2iso @$expiration
}

expiration_json() {
    jq -r .expiration "$@"
}

vault2aws() {
    local ttl expiration
    if ! ttl="$(jq -r .lease_duration "$1")"; then
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
        expiration=$(expiration_json "$1")
        jq -r '
        {
            Version: 1,
            AccessKeyId: .data.access_key,
            SecretAccessKey: .data.secret_key,
            SessionToken: .data.security_token,
            Expiration: "'$(unix2iso @$expiration)'"
        }' $1
    fi
}

vault_render_file() {
    local file="$1" tmp
    if [ -z "$file" ] || [ "$file" = - ]; then
        tmp=$(mktemp -t vaultXXXXXX.json)
        cat - > "$tmp"
        file="$tmp"
    fi
    if $EXPORT_ENV; then
        echo "export AWS_ACCESS_KEY_ID=\"$(jq -r .data.access_key $file)\""
        echo "export AWS_SECRET_ACCESS_KEY=\"$(jq -r .data.secret_key $file)\""
        echo "export AWS_SESSION_TOKEN=\"$(jq -r .data.security_token $file)\""
    elif $EXPORT_PROFILE; then
        echo "[$PROFILE]"
        echo aws_access_key_id = $(jq -r .data.access_key $file)
        echo aws_secret_access_key = $(jq -r .data.secret_key $file)
        echo aws_session_token = $(jq -r .data.security_token $file)
        echo
    else
        vault2aws "$file"
    fi

    test -z "$tmp" || rm -f "$tmp"
}

main() {
    while [ $# -gt 0 ]; do
        local cmd="$1"
        shift
        case "$cmd" in
        -h | --help) usage ;;
        -i | --install) INSTALL=true ;;
        --check) vault_sanity ;;
        --account)
            ACCOUNT="$2"
            shift
            ;;
        --role)
            ROLE="$2"
            shift
            ;;
        --type)
            TYPE="$2"
            shift
            ;;
        -c | --clear) CLEAR=true ;;
        -f | --file)
            FILE="$2"
            shift
            ;;
        --path)
            AWSPATH="$2"
            shift
            ;;
        --export-env) EXPORT_ENV=true ;;
        --export-profile) EXPORT_PROFILE=true ;;
        --profile)
            PROFILE="$2"
            shift
            ;;
        --ttl)
            TTL="$2"
            shift
            ;;
        --) ;;
        -*) usage "Unknown argument $cmd" ;;
        *) break ;;
        esac
    done
    if [ -n "$FILE" ]; then
        vault_render_file "$FILE"
        exit $?
    fi
    test -e $HOME/.aws || mkdir -m 0700 $HOME/.aws
    test -e $HOME/.aws/credentials || touch $HOME/.aws/credentials
    if [ -z "$AWSPATH" ]; then
        AWSPATH="$ACCOUNT/$TYPE/$ROLE"
    fi
    if $INSTALL; then
        vault_install_credential_helper
        exit $?
    fi
    VAULTCACHE="$HOME/.aws/cache/${AWSPATH}.json"
    if $CLEAR; then
        say "Clearing cached credentials for $AWSPATH .."
        rm -f -- "$VAULTCACHE"
        exit $?
    fi
    mkdir -m 0700 -p $(dirname $VAULTCACHE)
    export TMPDIR=$HOME/.aws/tmp
    mkdir -m 0700 -p $TMPDIR
    TMP=$(mktemp -t vaultXXXXXX.json)
    trap "rm -f $TMP" EXIT
    if [ -s "$VAULTCACHE" ]; then
        NOW=$(date +%s)
        EXPIRATION=$(expiration_json "$VAULTCACHE")
        if [[ $EXPIRATION == 0 ]] || [[ $((EXPIRATION - NOW)) -gt 300 ]]; then
            vault_render_file "$VAULTCACHE"
            exit $?
        fi
    fi
    rm -f -- "$VAULTCACHE"

    case "$AWSPATH" in
    */sts/*) vault write -format=json "$AWSPATH" ttl=$TTL > "$TMP" ;;
    */creds/*) vault read -format=json "$AWSPATH" ttl=$TTL > "$TMP" ;;
    *) die "Unknown type of path $AWSPATH" ;;
    esac
    if [ $? -ne 0 ]; then
        echo >&2 "ERROR: Failed to get valid vault creds for $AWSPATH"
        echo >&2 "Check ~/.vault-token, VAULT_TOKEN and $TMP"
        echo >&2 "VAULT_ADDR=$VAULT_ADDR"
        exit 1
    fi

    LEASE_DURATION=$(jq -r .lease_duration "$TMP")
    if [ $? -eq 0 ] && [ -n "$LEASE_DURATION" ]; then
        EXPIRATION=$(date -d "$LEASE_DURATION seconds" +%s)
        jq -r '. + { expiration: '$EXPIRATION'}' "$TMP" > "${TMP}.2" \
            || die "Failed to save converted vault credentials"
        mv "${TMP}.2" "$TMP"
    fi
    mv "$TMP" "$VAULTCACHE"

    vault_render_file "$VAULTCACHE"
}

main "$@"
