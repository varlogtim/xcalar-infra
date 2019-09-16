#!/bin/bash
# This script is not completed because the item gets punted

set -ex
export XLRINFRADIR=${XLRINFRADIR-$HOME/xcalar-infra}
export XLRGUIDIR=${XLRGUIDIR-$XLRINFRADIR/xcalar-gui}

if ! aws s3 ls ${S3_BUCKET}; then
    aws s3 mb "s3://${S3_BUCKET}" --region ${AWS_REGION}
fi

echo "Building XD"
cd $XLRGUIDIR
npm install --save-dev
node_modules/grunt/bin/grunt init
node_modules/grunt/bin/grunt installer --product="Cloud"

aws s3 sync --acl public-read ./xcalar-gui s3://${S3_BUCKET}/${TARGET_PATH} --region ${AWS_REGION}
# aws cloudfront create-invalidation --distribution-id ${DISTRIBUTION_ID} --paths / ${TARGET_PATH}