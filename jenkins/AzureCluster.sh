#!/bin/bash

if [ -z "$EMAIL" ]; then
    echo "MUST SPECIFY EMAIL"
    exit 1
fi

source $XLRINFRADIR/azure/azure-sh-lib

cd $XLRINFRADIR/azure

az_login

if [ "${INSTALLER_URL:0:1}" == / ]; then
    echo "Uploading $INSTALLER_URL to Azure Blobstore..."
    INSTALLER_URL="$(installer-url.sh -d az $INSTALLER_URL)" || exit 1
fi
INSTALLER_URL="${INSTALLER_URL%\?*}"
echo "Installer: $INSTALLER_URL"

APP=xdp-azurecluster-${BUILD_NUMBER}
GROUP=${APP}-rg

set -e

TMPDIR=$(mktemp -d -t azure.XXXXXX)
LOCATION=${LOCATION:-westus2}

if ! az group show -g $GROUP > /dev/null 2>&1; then
    say "Creating a new resource group $GROUP"

    az group create -g $GROUP -l $LOCATION -ojson > /dev/null
    trap "az group delete -g $GROUP --no-wait -y" EXIT
fi

if ! az_deploy -g $GROUP -l $LOCATION -i "$INSTALLER_URL" --count $NUM_NODES \
    --size $INSTANCE_TYPE --name $APP --email "$EMAIL" > output.json; then
    cat output.json >&2
    echo >&2 "Failed to deploy your template"
    exit 1
fi

URL="https://${APP}.${LOCATION}.cloudapp.azure.com"

echo "Login at $URL using User: xdpadmin, Password: Welcome1"

echo $URL > url.txt

trap '' EXIT
exit 0
