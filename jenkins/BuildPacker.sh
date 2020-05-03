#!/bin/bash
set -e

export XLRDIR=${XLRDIR:-$PWD}
export XLRINFRADIR=${XLRINFRADIR:-$PWD/xcalar-infra}
export PATH=$XLRDIR/bin:$XLRINFRADIR/bin:$PATH

cd $XLRDIR
. doc/env/xc_aliases

cd $XLRINFRADIR
. bin/activate

vault kv get -format=json -field=data secret/data/xcalar_licenses/cloud | jq -r '{license:.}' > license.json
export LICENSE_DATA=$PWD/license.json

(

for BUILDER in ${BUILDERS//,/ }; do
    DIR=$(dirname ${XLRINFRADIR}/${PACKERCONFIG}) && \
    cd $DIR && \
    make $BUILDER "INSTALLER=$INSTALLER" "INSTALLER_URL=$INSTALLER_URL"
done
)
exit $?
