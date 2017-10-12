#!/bin/bash
set -e

BUCKET=xcrepo
KEYBASE=temp/bysha1

test $# -eq 0 && set -- xdp-standard-package.zip deploy

get_sha1 () {
    sha1sum "$1" | cut -d' ' -f1 | cut -c1-8
}

sha1url () {
    local bn="$(basename $1)"
    echo "https://s3-us-west-2.amazonaws.com/${BUCKET}/${KEYBASE}/$(get_sha1 $1)/${bn}"
}

rawurlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
     c=${string:$pos:1}
     case "$c" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * )               printf -v o '%%%02x' "'$c"
     esac
     encoded+="${o}"
  done
  echo "${encoded}"
}

az_rg_deployment_url () {
    GROUP_SHOW=($(az group show --resource-group "$1" --output tsv)) && \
    echo "https://portal.azure.com/#resource/${GROUP_SHOW[0]}/deployments"
}

upload () {
    local src="$1"
    local dst="${2:-$src}"
    aws s3 cp --quiet --acl public-read --metadata-directive REPLACE --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' $src "s3://${BUCKET}/${KEY}/${dst}" && \
    local url="https://s3-us-west-2.amazonaws.com/${BUCKET}/${KEY}/${dst}"
    echo "$url"
}

check () {
    if echo "$1" | grep -q '\.json$'; then
        jq -r '.' < "$1" >/dev/null
    elif echo "$1" | grep -q '\.sh$'; then
        bash -n "$1"
    fi
}

XDP=xdp-standard-package.zip
if [ "$1" = $XDP ]; then
    rm -f xdp-standard-package.zip payload.tar.gz
    make xdp-standard-package.zip
fi

while getopts "u:" cmd; do
    case "$cmd" in
        u) UPLOAD="$OPTARG"; sha1url "$UPLOAD"; exit 0;;
        --) break;;
        -*) echo >&2 "Unknown $cmd ...";;
    esac
done

if ! test -n "$1"; then
    set -- "$XDP"
fi

BN="$(basename $1)"
SHA1="$(get_sha1 $1)"
KEY="$KEYBASE/$SHA1"

upload "$1"

set -x
if echo "$1" | grep -q '\.zip$'; then
    mkdir -p $KEY
    zip=$(readlink -f $1)
    cd $KEY
    unzip -o $zip
    artifactsLoc="https://s3-us-west-2.amazonaws.com/${BUCKET}/${KEY}"
    bootstrap_url="$(upload bootstrap.sh bootstrap.sh)"
    template_url="$(sed -e 's|"defaultValue": "https://.*$|"defaultValue": "'${artifactsLoc}'/"|g' mainTemplate.json | upload - mainTemplate.json)"
    createui_url="$(upload createUiDefinition.json)"
    payload_url="$(upload payload.tar.gz)"
    cd - >/dev/null
    urlcode="$(rawurlencode "{\"initialData\":{},\"providerConfig\":{\"createUiDefinition\":\"$createui_url\"}}")"
	URL="https://portal.azure.com/?clientOptimizations=false#blade/Microsoft_Azure_Compute/CreateMultiVmWizardBlade/internal_bladeCallId/anything/internal_bladeCallerParams/$urlcode"
    echo "<br/><a href=\"$URL\">[[Preview #${count}]]</a>" >> azure.html
	echo "azure.html"
	google-chrome "$URL"
    if [ "$2" = deploy ]; then
        COUNT="$(cat count.txt 2>/dev/null || echo 0)"
        COUNT=$((COUNT+1))
        echo $COUNT > count.txt
        CLUSTER=${USER}-${COUNT}-cluster
        DNS=dns-$CLUSTER
        GROUP=${USER}-${COUNT}-rg
        VMNAME=${USER}-${COUNT}-vm
        LOCATION="${LOCATION:-westus2}"
        az group create -l "${LOCATION}" --name "$GROUP" --tags "Email:`git config user.email`"
        DEPLOY="${USER}-${COUNT}-deploy"
        echo "GROUP=$GROUP" >> local.mk
        test -e parameters.main.json && echo "=== here's your original parameters.main.json ===" && cat parameters.main.json
        echo "====== save your params to parameters.main.json and press any key ====="
        read
        az group deployment create --template-uri "${template_url}" --parameters @parameters.main.json --parameters _artifactsLocation="$artifactsLoc" --parameters _artifactsLocationSasToken='' \
                        --parameters "location=${LOCATION}" --parameters clusterName=${CLUSTER} \
                        --parameters domainNameLabel=${DNS} \
                        -g "${GROUP}" --name "${DEPLOY}" --no-wait
        az group deployment wait --exists -g "$GROUP" --name "$DEPLOY"
        google-chrome "$(az_rg_deployment_url $GROUP $DEPLOY)"
    else
        echo "$template_url"
        echo "az group deployment create --template-uri \"${template_url}\" --parameters @parameters.main.json --parameters _artifactsLocation=\"$artifactsLoc\" --parameters _artifactsLocationSasToken='' --parameters clusterName=${GROUP%-rg}-cluster --parameters dnsNameLabel=anything-foo --parameters location=\${LOCATION} -g \${GROUP} --name \${DEPLOY} --no-wait"
    fi
fi
