#!/bin/bash
set -e

. infra-sh-lib
. aws-sh-lib

packer_do() {
    local cmd="$1"
    shift
    if [ -e $HOME/.packer-vars ]; then
        USER_VARS="$HOME/.packer-vars"
    fi
    packer $cmd \
        -var "product=$PRODUCT" \
        -var "version=$INSTALLER_VERSION" \
        -var "build_number=$INSTALLER_BUILD_NUMBER" \
        -var "image_build_number=$IMAGE_BUILD_NUMBER" \
        -var "installer_url=$INSTALLER_URL" \
        ${USER_VARS+-var-file $USER_VARS} \
        ${VAR_FILE+-var-file $VAR_FILE} "$@"
}

filename_from_url() {
    basename "$1" | sed -e 's/\?.*$//g'
}

version_build_from_filename() {
    grep -Eow '[0-9\.-]+' <<< "$1" | tr - ' '
}

check_or_upload_installer() {
    if [ -z "$INSTALLER_URL" ]; then
        if [ -z "$INSTALLER" ]; then
            INSTALLER="$(latest-installer.sh)"
        fi
        INSTALLER_URL="$(installer-url.sh -d s3 $INSTALLER)"
    fi

    if [[ $INSTALLER_URL =~ ^http ]]; then
        if URL_CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Range: bytes=0-500" -L "$INSTALLER_URL"); then
            if ! [[ $URL_CODE =~ ^2 ]]; then
                echo >&2 "InstallerURL failed! $INSTALLER_URL not found!"
                exit 1
            fi
        else
            echo >&2 "InstallerURL failed! $INSTALLER_URL not found!"
            exit 1
        fi
    elif [[ $INSTALLER_URL =~ ^s3:// ]]; then
        if ! aws_s3_head_object $INSTALLER_URL > /dev/null; then
            echo >&2 "InstallerURL failed! $INSTALLER_URL not found!"
            exit 1
        fi
    fi
}

while [ $# -gt 0 ]; do
    cmd="$1"
    case "$cmd" in
    --osid)
        OSID="$2"
        shift 2
        ;;
    --installer)
        INSTALLER="$2"
        shift 2
        ;;
    --installer-url)
        INSTALLER_URL="$2"
        shift 2
        ;;
    --template)
        TEMPLATE="$2"
        shift 2
        ;;
    --var-file)
        VAR_FILE="$2"
        shift 2
        ;;
    --)
        shift
        break
        ;;
    --*)
        echo >&2 "ERROR: Unknown parameter $cmd"
        exit 1
        ;;
    -*) break ;;
    *) if test -e "$1"; then
        TEMPLATE="$1"
        shift
       else
         echo >&2 "ERROR: Don't understand $cmd ..."
         exit 1
       fi
       ;;
    esac
done

TMPDIR=$(mktemp -d -t packerXXXXXX)
trap "rm -rf $TMPDIR" exit

if [ -n "$TEMPLATE" ]; then
    if [[ $TEMPLATE =~ .yaml$ ]] || [[ $TEMPLATE =~ .yml$ ]]; then
        cfn-flip < "$TEMPLATE" > $TMPDIR/template.json
        TEMPLATE="$TMPDIR/template.json"
    fi
    cat $VAR_FILE  vars/shared.yaml | cfn-flip > $TMPDIR/vars.json
    VAR_FILE=$TMPDIR/vars.json
    set -- "$@" "$TEMPLATE"
fi

check_or_upload_installer

IMAGE_BUILD_NUMBER=${IMAGE_BUILD_NUMBER:-1}
PRODUCT="${PRODUCT:-xdp-standard}"

INSTALLER_VERSION_BUILD=($(version_build_from_filename "$(filename_from_url "$INSTALLER_URL")"))
INSTALLER_VERSION="${INSTALLER_VERSION_BUILD[0]}"
INSTALLER_BUILD_NUMBER="${INSTALLER_VERSION_BUILD[1]}"

set +e
packer_do validate ${*/-color=*/} \
    && packer_do build "$@"
if [ $? -ne 0 ]; then
    trap - EXIT
    echo "Failed! See $TMPDIR"
    exit 1
fi
