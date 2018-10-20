#!/bin/bash
set -e

. infra-sh-lib
. aws-sh-lib

packer_do() {
    local cmd="$1"
    shift
    packer $cmd \
        -var "product=$PRODUCT" \
        -var "version=$INSTALLER_VERSION" \
        -var "build_number=$INSTALLER_BUILD_NUMBER" \
        -var "image_build_number=$IMAGE_BUILD_NUMBER" \
        -var "installer_url=$INSTALLER_URL" \
        -var-file=$HOME/.packer-vars "$@"
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
    --)
        shift
        break
        ;;
    --*)
        echo >&2 "ERROR: Unknown parameter $cmd"
        exit 1
        ;;
    -*) break ;;
    esac
done

if [ -n "$TEMPLATE" ]; then
    if [[ $TEMPLATE =~ .yaml$ ]] || [[ $TEMPLATE =~ .yml$ ]]; then
        TMP=$(mktemp packerXXXXXX.json)
        trap "rm $TMP" exit
        cfn-flip < "$TEMPLATE" > $TMP
        TEMPLATE=$TMP
    fi
    set -- "$@" "$TEMPLATE"
fi

check_or_upload_installer

IMAGE_BUILD_NUMBER=${IMAGE_BUILD_NUMBER:-1}
PRODUCT="${PRODUCT:-xdp-standard}"

INSTALLER_VERSION_BUILD=($(version_build_from_filename "$(filename_from_url "$INSTALLER_URL")"))
INSTALLER_VERSION="${INSTALLER_VERSION_BUILD[0]}"
INSTALLER_BUILD_NUMBER="${INSTALLER_VERSION_BUILD[1]}"

packer_do validate ${*/-color=*/}
packer_do build "$@"
