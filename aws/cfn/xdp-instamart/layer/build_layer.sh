#!/usr/bin/env bash
set -e

DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
ARGS=("$@")
LAYER_NAME=${1?Must specify layer name}  # input layer, retrived as arg
ZIP_ARTIFACT=${LAYER_NAME}.zip
shift
PUBLISH=0
RUNTIME=python3.6
while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        --publish) PUBLISH=1;;
        --runtime) RUNTIME="$1"; shift;;
        *) echo >&2 "Unknown argument $cmd"; exit 1;;
    esac
done

if [ -z "$container" ]; then
    docker run --rm -e container=docker -v $DIR:/var/task:z -w /var/task lambci/lambda:build-${RUNTIME} bash -x $(basename "${BASH_SOURCE[0]}") "${ARGS[@]}"

    if ((PUBLISH)); then
        echo "Publishing layer to AWS..."
        aws lambda publish-layer-version --layer-name ${LAYER_NAME} --zip-file fileb://${ZIP_ARTIFACT} --compatible-runtimes ${RUNTIME}
        VERSION=$(aws lambda list-layer-versions --layer-name ${LAYER_NAME} --query 'LayerVersions[0].Version')
        aws lambda add-layer-version-permission --statement-id xaccount-$(date +%s) --action lambda:GetLayerVersion --principal '*' --layer-name ${LAYER_NAME} --version-number ${VERSION}
    fi
    exit $?
fi

LAYER_BUILD_DIR="$(mktemp -t -d python.XXXXXX)/python"
mkdir -p $LAYER_BUILD_DIR

${RUNTIME} -m pip --isolated install -t ${LAYER_BUILD_DIR} -r requirements.txt -c constraints.txt

if ls *.py >/dev/null 2>&1; then
    cp -v *.py ${LAYER_BUILD_DIR}
fi

rm -f ${ZIP_ARTIFACT}
cd ${LAYER_BUILD_DIR}/..
zip -9r -q ${DIR}/${ZIP_ARTIFACT} ./python/
cd - >/dev/null
chown $(stat -c %u $DIR) ${DIR}/${ZIP_ARTIFACT} .
rm -rf ${LAYER_BUILD_DIR}
