#!/bin/bash

S3URL="${1?Need to specify s3url}"


S3URL="${S3URL#s3://}"

BUCKET="${S3URL%%/*}"
KEY="${S3URL#*/}"

aws s3api put-object-acl --acl public-read --bucket "${BUCKET}" --key "${KEY}"

echo "https://${BUCKET}.s3.amazonaws.com/${KEY}"
