#!/bin/bash

. infra-sh-lib

S3PREFIX=${S3PREFIX:-cfn/}
S3BUCKET=${S3BUCKET:-xcrepo}
ENV=${ENV:-dev}
VERSION=${VERSION:-1.0}
RELEASE=${RELEASE:-1}

while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        --bucket=*) S3BUCKET="${cmd#*=}";;
        -b|--bucket) S3BUCKET="$1"; shift;;
        --prefix=*) S3PREFIX="${cmd#*=}";;
        --prefix) S3PREFIX="$1"; shift;;
        --env=*) ENV="${cmd#*=}";;
        -e|--env) ENV="$1"; shift;;
        --project=*) PROJECT="${cmd#*=}";;
        -p|--project) PROJECT="$1"; shift;;
        --release=*) RELEASE="${cmd#*=}";;
        -r|--release) RELEASE="$1"; shift;;
        --version=*) VERSION="${cmd#*=}";;
        --version) VERSION="$1"; shift;;
    esac
done

if [ -z "$PROJECT" ]; then
    if [ "${PWD#$XLRINFRADIR/aws/cfn/}" = $(basename $PWD) ]; then
        PROJECT=$(basename $PWD)
    else
        die "Must specify project"
    fi
fi

echo "https://${S3BUCKET}.s3.amazonaws.com/${S3PREFIX}${ENV:+$ENV/}${PROJECT:+$PROJECT/}${VERSION:+$VERSION}${RELEASE:+-$RELEASE}/"
