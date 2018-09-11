#!/bin/bash


s3_sync() {
    aws s3 sync --acl public-read --metadata-directive REPLACE --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' "$@"
}


s3_sync --exclude '*.swp' --exclude '*.swo' --delete ./ s3://xcrepoe1/cfn-deploy/
