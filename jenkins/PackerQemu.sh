#!/bin/bash
#
# shellcheck disable=SC1091,SC2086

set -e

export XLRINFRADIR=${XLRINFRADIR:-$PWD}
export PATH=$XLRINFRADIR/bin:/opt/xcalar/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin:$HOME/.local/bin:$HOME/bin
export OUTDIR=${OUTDIR:-$PWD/output}
export MANIFEST=$OUTDIR/packer-manifest.json
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-west-2}
export PROJECT=${PROJECT:-xdp-awsmp}

export PUPPETSRCDIR=$PWD/puppet
export OUTPUT_DIRECTORY=/netstore/builds/byJob/${JOB_NAME}/${BUILD_NUMBER}
mkdir -p $OUTPUT_DIRECTORY

. infra-sh-lib
. aws-sh-lib

export VAULT_TOKEN=$($XLRINFRADIR/bin/vault-auth-puppet-cert.sh --print-token)

if [ -n "$JENKINS_URL" ]; then
    if test -e .venv/bin/python2; then
        REBUILD_VENV=true
    fi
fi
if [ -n "$REBUILD_VENV" ]; then
    rm -rf .venv
fi

if ! make venv; then
    make clean
    make venv
fi

source .venv/bin/activate || die "Failed to activate venv"

test -d "$OUTDIR" || mkdir -p "$OUTDIR"
if ! test -e $MANIFEST; then
    curl -fsSL ${JOB_URL}/lastSuccessfulBuild/artifact/output/packer-manifest.json -o $MANIFEST || true
fi

cd packer/qemu

if ! test -e $(basename $MANIFEST); then
    cp $MANIFEST . || true
fi

make el7-jenkins_slave-qemu/tdhtest OUTPUT_DIRECTORY=$OUTPUT_DIRECTORY OUTDIR=$OUTDIR PUPPETSRCDIR=$PUPPETSRCDIR OUTDIR=$OUTDIR
if test -e $(basename $MANIFEST); then
    cp $(basename $MANIFEST) $MANIFEST
fi
