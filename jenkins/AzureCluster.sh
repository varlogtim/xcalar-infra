#!/bin/bash
set -x

source $XLRINFRADIR/azure/azure-sh-lib || exit 1

cd $XLRINFRADIR/azure

az_login

if [ "${INSTALLER_URL:0:1}" == / ]; then
    echo "Uploading $INSTALLER_URL to Azure Blobstore..."
    INSTALLER_URL="$(installer-url.sh -d az $INSTALLER_URL)" || exit 1
fi
INSTALLER_URL="${INSTALLER_URL%\?*}"
echo "Installer: $INSTALLER_URL"

if [ -z "$APP" ]; then
    if [ -n "$BUILD_USER" ]; then
        APP="xdp-${BUILD_USER}-${BUILD_NUMBER}"
    else
        APP="xdp-${JOB_NAME}-${BUILD_NUMBER}"
    fi
fi

APP="$(echo $APP | tr A-Z a-z | tr ' ' '-')"
GROUP=${APP}-rg

set -e

LOCATION=${LOCATION:-westus2}

if ! az group show -g $GROUP > /dev/null 2>&1; then
    say "Creating a new resource group $GROUP"

    az group create -g $GROUP -l $LOCATION -ojson > /dev/null
    trap "az group delete -g $GROUP --no-wait -y" EXIT
fi

if ! az_deploy -g $GROUP -l $LOCATION -i "$INSTALLER_URL" --count $NUM_NODES \
    --size $INSTANCE_TYPE --name "$APP" --parameters adminEmail="$ADMIN_EMAIL" adminUsername="${ADMIN_USERNAME:-xdpadmin}" adminPassword="${ADMIN_PASSWORD:-Welcome1}" \
    licenseKey="$LICENSE_KEY" > output.json; then
    cat output.json >&2
    echo >&2 "Failed to deploy your template"
    exit 1
fi

URL="https://${APP}.${LOCATION}.cloudapp.azure.com"

echo "Login at $URL using User: xdpadmin, Password: Welcome1"

echo $URL > url.txt

trap '' EXIT
exit 0
