#!/bin/bash
set -e

export XLRDIR=${XLRDIR:-$PWD}
export XLRINFRADIR=${XLRINFRADIR:-$PWD/xcalar-infra}
export PATH=$XLRDIR/bin:$XLRINFRADIR/bin:$PATH

cd $XLRDIR
. doc/env/xc_aliases

export PATH="$XLRINFRADIR/bin:$XLRDIR/bin:$PATH"

cd $XLRINFRADIR
. bin/activate

export VAULT_TOKEN=$($XLRINFRADIR/bin/vault-auth-puppet-cert.sh --print-token)
vault kv get -format=json -field=data secret/xcalar_licenses/cloud | jq -r '{license:.}' > license.json
export LICENSE_DATA=$PWD/license.json

(

for BUILDER in ${BUILDERS//,/ }; do
    DIR=$(dirname ${XLRINFRADIR}/${PACKERCONFIG}) && \
    cd $DIR && \
    make $BUILDER "INSTALLER=$INSTALLER" "INSTALLER_URL=$INSTALLER_URL" "REGISTRY=${REGISTRY:-registry.int.xcalar.com}"
done
)
exit $?
