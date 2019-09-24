#!/bin/bash
#
# Script to manage AWS credentials generated in Vault. Supports multiple profiles,
# caching, and is a plugin to the awscli.
#
# In the awscli credentials configuration, ~/.aws/credentials, you can specify keys
# directly, or you can specify a credentials provider as an external script that is
# responsible for providing awscli with valid credentials. This is such a script.
#
# ; from ~/.aws/credentials
# [vault]  ; <-- or any other profile name
# credential_process=/home/abakshi/bin/vault-aws-credentials-provider.sh --path aws-xcalar/sts/poweruser
#
# From then on when calling `awscli --profile vault`, this script is called, which
# in turn calls vault

# <-----------------------------------------------------------------------------
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
#     "security_token": "FQoDYXdzENj//////////wEaDNSxT0hN2kESqT1U/iL6AVrZFwm"
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
VAULTCACHE_BASE="$HOME/.aws/cache"
TTL=4h
TYPE="sts"
CLEAR=false
EXPORT_ENV=false
EXPORT_PROFILE=false
INSTALL=false
UNMET_DEPS=()
DEBUG=0
export AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

usage() {
    cat <<EOF >&2

     $(basename $0) [--account ACCOUNT] [--role ROLE]
        [--install] [--profile PROFILE] [--ttl NUM] [--clear]

    --account  ACCOUNT   AWS Account to use (default $ACCOUNT (xcalar, xcalar-poc, test, prod)
    --role     ROLE      AWS Role (default: $ROLE)
    --install            Install into ~/.aws/credentials to have awscli automatically retrieve keys
    --ttl      TTL       TTL for token, min is 15m, max is 12h (default: $TTL)
    --profile  PROFILE   AWS CLI Profile to populate from ~/.aws/credentials (default: $PROFILE)

    -c|--clear           Clear all existing token (if any)

    Advanced options ...
      [--check] [--path PATH] [-e|--export-env] [--export-profile]
        [-f|--file FILE|-]

    --check              Sanity check your installation
    --path     PATH      Complete vault path to use (default: $ACCOUNT/$TYPE/$ROLE)
    -f|--file    FILE|-  Read existing credentials from FILE or - (stdin)
    -e|--export-env      Show AWS environment variables that you can use for auth
    --export-profile     Print credentials in AWS format credential format
EOF
    say "$*"
    exit 2
}

say() {
    echo >&2 "$1"
}

die() {
    if [ -z "$1" ]; then
        exit 1
    fi
    say "ERROR: $1"
    say
    say "For more information and detailed instructions see the Vault Wiki:"
    say "http://wiki.int.xcalar.com/mediawiki/index.php/Vault"
    say
    exit ${2:-1}
}

if [[ $OSTYPE =~ darwin ]]; then
    please_install() {
        say
        say "You need '$1'. The easiest way to install '$1' is via 'brew'"
        if ! command -v brew >/dev/null && [ "$brew_warn" != true ]; then
            brew_warn=true
            say "Alas, you need to install 'brew', a package manager for OSX"
            say
            echo >&2 '  /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"'
            say
            say "For more information and detailed instructions on Brew see:"
            say "http://wiki.int.xcalar.com/mediawiki/index.php/Homebrew"
            say
            say "Once you have it, run:"

        else
            say "Try running the following:"
        fi

        say
        say " brew update"
        say " brew install ${2:-$1}"
    }
    date() {
        gdate "$@"
    }
    stat() {
        gstat "$@"
    }
    sed() {
        gsed "$@"
    }
    readlink() {
        greadlink "$@"
    }
else
    please_install() {
        say
        if command -v apt-get >/dev/null; then
            say "You need to install $1. Try 'apt-get install ${2:-$1}'"
        else
            say "You need to install $1. Try 'yum install --enablerepo=\"xcalar-*\" ${2:-$1}'"
        fi
    }
fi

please_have() {
    if ! command -v "$1" >/dev/null; then
        please_install "$@"
        UNMET_DEPS+=($1)
        return 1
    fi
}

cvault() {
    if [ -z "$VAULT_TOKEN" ]; then
        if test -e "$HOME/.vault-token"; then
            export VAULT_TOKEN="$(cat ~/.vault-token)"
        else
            die "Failed to find VAULT_TOKEN environment or ~/.vault-token file. Are you logged in?"
        fi
    fi
    local uri="$1"
    shift
    curl -sS -H "X-Vault-Token: $VAULT_TOKEN" "${VAULT_ADDR}/v1/${uri}" "$@"
}

vault_status() {
    local status
    if status="$(
        set -o pipefail
        cvault sys/health | jq -r .sealed
    )" && [ "$status" = false ]; then
        return 0
    fi
    return 1
}

remove_profile() {
    sed -i.bak '/^\['$1'\]/,/^$/d' "$2"
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
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
    aws_configure default.region $AWS_DEFAULT_REGION
    aws_configure default.s3.signature_version s3v4
    aws_configure default.s3.addressing_style path

    local dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    local filen="$(basename "${BASH_SOURCE[0]}")"

    cat >${AWS_SHARED_CREDENTIALS_FILE}.$$ <<EOF

[$PROFILE]
credential_process = "${dir}/${filen}" --path $AWSPATH

EOF

    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
    unset AWS_ACCESS_KEY_ID
    if ! AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE}.$$ aws --profile "$PROFILE" sts get-caller-identity --output json; then
        die "Failed to get your identity from AWS :("
    fi

    remove_profile "$PROFILE" "$AWS_SHARED_CREDENTIALS_FILE"
    cat ${AWS_SHARED_CREDENTIALS_FILE}.$$ >> ${AWS_SHARED_CREDENTIALS_FILE}
    rm ${AWS_SHARED_CREDENTIALS_FILE}.$$
    say "SUCCESS"

    say
    if [ "$PROFILE" = default ]; then
        say "   aws <cmd>"
        say ""
    else
        say "   aws --profile $PROFILE <cmd>"
        say ""
        say "To avoid having to add '--profile $PROFILE' to every awscli command, add the following to your ~/.bashrc"
        say "   export AWS_PROFILE=$PROFILE"
    fi
}

install_aws() {
    VENV_AWS=$HOME/.local/share/aws
    if ! test -e "${VENV_AWS}/bin/activate"; then
        venv_version=16.7.5
        venv_url="https://github.com/pypa/virtualenv/tarball/${venv_version}"
        venv_dir=$HOME/.local/share/venv
        mkdir -p $venv_dir
        curl -fsSL "$venv_url" | tar zxf - -C "$venv_dir" --strip-component=1
        if type deactivate >/dev/null 2>&1; then
            deactivate || true
            hash -r
        fi
        mkdir -p $VENV_AWS
        if command -v python3 >/dev/null; then
            python3 $venv_dir/virtualenv.py $VENV_AWS
        else
            python $venv_dir/virtualenv.py $VENV_AWS
        fi
        say "Installing awscli locally ..."
        $VENV_AWS/bin/pip install -q -U awscli || die "Failed to install awscli"
    fi
    . $VENV_AWS/bin/activate
}

vault_sanity() {
    say "Sanity checking your vault installation ..."
    local progs="jq vault curl" prog=''
    for prog in $progs; do
        please_have $prog
    done
    if [[ $OSTYPE =~ darwin ]]; then
        progs="gsed gdate greadlink gstat"
        for prog in $progs; do
            please_have $prog "coreutils"
        done
    fi
    echo "1..6"
    if [ ${#UNMET_DEPS[@]} -gt 0 ]; then
        echo "not ok    1  - missing dependencies ${UNMET_DEPS[*]}"
        die "You have unmet dependencies: ${UNMET_DEPS[*]}"
    fi
    echo "ok    1  - have all dependencies"
    local -a aws_version
    if ! aws_version=($(
        set -o pipefail
        aws --version 2>&1 | sed -E 's@^aws-cli/([0-9\.]+).*$@\1@g' | tr . ' '
    )); then
        echo "not ok    2  - awscli 15.40 or higher"
        die "awscli needs to be version 15.40 or higher. Use virtualenv and pip install -U awscli."
    fi
    if [ ${aws_version[1]} -lt 15 ]; then
        echo "not ok    2  - awscli 15.40 or higher"
        echo "ok    2  - awscli 15.40 or higher"
    elif [ ${aws_version[1]} -eq 15 ] && [ ${aws_version[2]} -lt 40 ]; then
        echo "not ok    2  - awscli 15.40 or higher"
        die "awscli needs to be version 15.40 or higher. Use virtualenv and pip install -U awscli."
    fi
    echo "ok    2  - awscli 15.40 or higher"

    if [ -z "$VAULT_ADDR" ]; then
        echo "not ok    3  - VAULT_ADDR is set"
        die "VAULT_ADDR not set. Please set 'export VAULT_ADDR=https://vault.service.consul:8200' to your ~/.bashrc or ~/.bash_profile"
    fi
    echo "ok    3  - VAULT_ADDR is set"
    if ! curl -o /dev/null -k -fsS "$VAULT_ADDR"; then
        echo "not ok    4  - failed to connect to vault"
        die "Failed to connect to VAULT_ADDR=$VAULT_ADDR"
    fi
    if ! curl -o /dev/null -fsS "$VAULT_ADDR"; then
        echo "not ok    4  - failed to securely connect to vault"
        die "Failed to connect to VAULT_ADDR=$VAULT_ADDR in a secure fashion. Please check http://wiki.int.xcalar.com/mediawiki/index.php/Xcalar_Root_CA"
    fi
    echo "ok    4  - connected to vault"
    local display_name
    if ! display_name=$(
        set -o pipefail
        cvault auth/token/lookup-self | jq -r .data.display_name
    ); then
        echo "not ok    5  - failed to look up your token"
        die "Failed to look you up. Are you logged into vault? Try 'vault login -method=ldap username=jdoe'. Your username is your LDAP username (usually the part before @xcalar.com in your email)"
    fi
    echo "ok    5  - verified your token with vault (display_name: $display_name)"
    if ! vault_status; then
        echo "not ok    6  - checked vault status"
        die "Failed to get 'vault status', or vault is sealed"
    fi
    echo "ok    6  - checked vault status"
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
    if ! jq -r .expiration "$@" 2>/dev/null; then
        return 1
    fi
}

vault_update_expiration() {
    local lease_duration expiration
    if ! lease_duration=$(jq -r .lease_duration "$1"); then
        return 1
    fi
    if [ -z "$lease_duration" ]; then
        return 1
    fi
    if ! expiration=$(date -d "$lease_duration seconds" +%s); then
        return 1
    fi
    jq -r '. + { expiration: '$expiration'}' "$1"
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
    local file="$1" tmp=''
    if [ -z "$file" ] || [ "$file" = - ]; then
        tmp=$(mktemp ${TMPDIR}/vaultXXXXXX.json)
        cat - >"$tmp"
        file="$tmp"
    fi
    if $EXPORT_ENV; then
        echo "export AWS_ACCESS_KEY_ID=\"$(jq -r .data.access_key $file)\""
        echo "export AWS_SECRET_ACCESS_KEY=\"$(jq -r .data.secret_key $file)\""
        echo "export AWS_SESSION_TOKEN=\"$(jq -r .data.security_token $file)\""
    elif $EXPORT_PROFILE; then
        echo "[$PROFILE]"
        echo "aws_access_key_id = $(jq -r .data.access_key $file)"
        echo "aws_secret_access_key = $(jq -r .data.secret_key $file)"
        echo "aws_session_token = $(jq -r .data.security_token $file)"
        echo
    else
        if ! vault2aws "$file"; then
            test -z "$tmp" || rm -f "$tmp"
            die "Failed to render $file"
        fi
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
            --check)
                vault_sanity
                exit $?
                ;;
            --account)
                ACCOUNT="$1"
                shift
                ;;
            --role)
                ROLE="$1"
                shift
                ;;
            --type)
                TYPE="$1"
                shift
                ;;
            -c | --clear) CLEAR=true ;;
            -f | --file)
                FILE="$1"
                shift
                ;;
            --path)
                AWSPATH="$1"
                shift
                ;;
            -e | --export-env) EXPORT_ENV=true ;;
            --export-profile) EXPORT_PROFILE=true ;;
            --profile)
                PROFILE="$1"
                shift
                ;;
            --ttl)
                TTL="$1"
                shift
                ;;
            --) break ;;
            *) usage "Unknown argument $cmd" ;;
        esac
    done
    if [ -n "$ACCOUNT" ]; then
        case "$ACCOUNT" in
            test|xcalar-test) ACCOUNT="aws-test";;
            sophia) ACCOUNT="aws-sophia";;
            prod|xcalar-prod) ACCOUNT="aws-prod";;
            pegasus|xcalar-pegasus) ACCOUNT="aws-pegasus";;
            poc|xcalar-poc) ACCOUNT="aws-xcalar-poc";;
            aws|default|xcalar) ACCOUNT="aws-xcalar";;
            *) die "Unknown account: $ACCOUNT";;
        esac
    fi

    test -e "$(dirname ${AWS_SHARED_CREDENTIALS_FILE})" || mkdir -m 0700 "$(dirname ${AWS_SHARED_CREDENTIALS_FILE})"
    if [ -z "$AWSPATH" ]; then
        AWSPATH="$ACCOUNT/$TYPE/$ROLE"
    fi
    VAULTCACHE="${VAULTCACHE_BASE}/${AWSPATH}.json"
    if $CLEAR; then
        say "Clearing cached credentials for $AWSPATH .."
        rm -f -- "$VAULTCACHE"
        exit $?
    fi
    if [ -n "$FILE" ]; then
        vault_render_file "$FILE"
        exit $?
    fi
    if $INSTALL; then
        vault_install_credential_helper
        exit $?
    fi
    mkdir -m 0700 -p "$(dirname $VAULTCACHE)"
    export TMPDIR="$HOME/.aws/tmp"
    mkdir -m 0700 -p "$TMPDIR"
    TMP="$(mktemp ${TMPDIR}/vaultXXXXXX.json)"
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

    case "$TYPE" in
        sts) cvault "$AWSPATH" -d '{"ttl": "'$TTL'"}' -X POST >"$TMP" ;;
        creds) cvault  "$AWSPATH" -d '{"ttl": "'$TTL'"}' -X GET >"$TMP" ;;
        *) die "Unknown type of path $AWSPATH" ;;
    esac
    if [ $? -ne 0 ]; then
        echo >&2 "ERROR: Failed to get valid vault creds for $AWSPATH"
        echo >&2 "Check ~/.vault-token, VAULT_TOKEN and $TMP"
        echo >&2 "VAULT_ADDR=$VAULT_ADDR"
        say
        die "Also make sure that $AWSPATH is valid path in vault"
    fi

    if vault_update_expiration "$TMP" > "${TMP}.2"; then
        mv "${TMP}.2" "$TMP"
    fi

#    LEASE_DURATION=$(jq -r .lease_duration "$TMP")
#    if [ $? -eq 0 ] && [ -n "$LEASE_DURATION" ]; then
#        EXPIRATION=$(date -d "$LEASE_DURATION seconds" +%s)
#        jq -r '. + { expiration: '$EXPIRATION'}' "$TMP" >"${TMP}.2" \
#            || die "Failed to save converted vault credentials"
#        mv "${TMP}.2" "$TMP"
#    fi

    vault_render_file "$TMP"
    mv "$TMP" "$VAULTCACHE"
}

main "$@"
