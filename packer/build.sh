#!/bin/bash
set -e

if [ -z "$INSTALLER_URL" ]; then
    if [ -z "$INSTALLER" ]; then
        INSTALLER="$(latest-installer.sh)"
    fi
    INSTALLER_URL="$(installer-url.sh -d s3 $INSTALLER)"
fi

s3_url_check() {
    local bucket_key="${1#s3://}"
    local bucket="${bucket_key/\/*/}"
    local key="${bucket_key#$bucket/}"
    aws s3api head-object --bucket $bucket --key $key
}


if [[ $INSTALLER_URL =~ ^http ]]; then
    if URL_CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Range: bytes=0-500" -L "$INSTALLER_URL"); then
        if [[ $URL_CODE =~ ^2 ]]; then
            echo >&2 "InstallerURL verified"
        else
            echo >&2 "InstallerURL failed!"
            exit 1
        fi
    else
        echo >&2 "InstallerURL failed!"
    fi
elif [[ $INSTALLER_URL =~ ^s3:// ]]; then
    s3_url_check $INSTALLER_URL
fi

if [ $# -eq 0 ]; then
    echo >&2 "Need to specify a  packer.json or yaml"
fi
PACKERCONFIG="$(mktemp -t packerXXXXXX.json)"
case "$1" in
    *.yaml) cfn-flip < $1 >  $PACKERCONFIG;;
    *) PACKERCONFIG="$1";;
esac
shift

BUILD_OSID=${BUILD_OSID:-amzn1}
IMAGE_BUILD_NUMBER=${IMAGE_BUILD_NUMBER:-3}
PRODUCT=xdp-standard
INSTALLER_FILE="$(basename "$INSTALLER_URL" | sed -e 's/\?.*$//g')"
VERSION_BUILD_NUMBER=($(grep -Eow '[0-9\.-]+' <<< $INSTALLER_FILE | tr - ' '))
VERSION="${VERSION_BUILD_NUMBER[0]}"
BUILD_NUMBER="${VERSION_BUILD_NUMBER[1]}"
packer validate -only=amazon-ebs-${BUILD_OSID} -var "ssh_username=ec2" -var "osid=${BUILD_OSID}" -var "version=$VERSION" -var "build_number=$BUILD_NUMBER" -var "product=$PRODUCT" -var "image_build_number=${IMAGE_BUILD_NUMBER}" \
    -var "installer_url=$INSTALLER_URL" \
    -var-file=$HOME/.packer-vars "$@" \
    $PACKERCONFIG
packer build    -only=amazon-ebs-${BUILD_OSID} -var "ssh_username=ec2" -var "osid=${BUILD_OSID}" -var "version=$VERSION" -var "build_number=$BUILD_NUMBER" -var "product=$PRODUCT" -var "image_build_number=${IMAGE_BUILD_NUMBER}" \
    -var "installer_url=$INSTALLER_URL" \
    -var-file=$HOME/.packer-vars "$@" \
    $PACKERCONFIG
