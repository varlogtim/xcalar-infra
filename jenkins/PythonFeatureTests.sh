#!/bin/bash

# TODO Put these in test.
export CLOUDSDK_COMPUTE_REGION=${CLOUDSDK_COMPUTE_REGION-us-central1}
export CLOUDSDK_COMPUTE_ZONE=${CLOUDSDK_COMPUTE_ZONE-us-central1-f}

export XLRDIR="$(pwd)/xcalar"
export XLRINFRADIR="$(pwd)/xcalar-infra"
export PATH="$XLRDIR/bin:$HOME/google-cloud-sdk/bin:$PATH"
export NOTPREEMPTIBLE=1 # No spurious failure, thanks.

# Clone needed repos.
rm -rf $XLRDIR
rm -rf $XLRINFRADIR

git clone "$GIT_REPOSITORY" xcalar
git clone 'ssh://gerrit.int.xcalar.com:29418/xcalar/xcalar-infra.git' xcalar-infra

cd $XLRINFRADIR
git checkout $XCALAR_INFRA_BRANCH

cd $XLRDIR
git remote add prototype 'git@git:/gitrepos/xcalar-prototype.git'
git fetch prototype

# We want to check out the backend pyTest code corresponding to the installer. Determine git SHA.
# XXX This almost definitely won't work most of the time.
sha=$(readlink $INSTALLER_PATH | cut -d- -f 3 | cut -d. -f 2)
git checkout $sha
git submodule init
git submodule update

# Only need to build to generate thrift bindings.
build clean
build config
build

otherOptions=""
if [ "$LEAVE_ON_FAILURE" = "true" ]; then
    otherOptions="--leaveOnFailure"
fi

./src/bin/tests/pyTest/PyFeatureTestsGceLauncher.sh --installer $INSTALLER_PATH --numNodes $NUM_NODES $otherOptions

