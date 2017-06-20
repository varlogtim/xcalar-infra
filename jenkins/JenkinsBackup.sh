#!/bin/bash

say () {
    echo >&2 "$*"
}

if [ -z "$BUILD_ID" ]; then
    say "Needs to be run as a Jenkins job"
    exit 1
fi
set -x
BUILD_ID=$(date +'%Y-%m-%d_%H%M%S')-$BUILD_NUMBER

mkdir -p $BUILD_ID/jobs

set +e

cp $JENKINS_HOME/*.xml $BUILD_ID/

# Secrets
cp $JENKINS_HOME/*.key $BUILD_ID/
cp $JENKINS_HOME/*.key.* $BUILD_ID/
cp -r $JENKINS_HOME/secrets $BUILD_ID/

# Users
cp -r $JENKINS_HOME/users $BUILD_ID/

set -e

# Jobs & History
#rsync -am --include="config.xml" \
#    --include="*/" \
#    --prune-empty-dirs \
#    $JENKINS_HOME/jobs/ $BUILD_ID/jobs/

rsync -am --include="config.xml" \
    --include="build.xml" \
    --include="log" \
    --include="changelog.xml" \
    --prune-empty-dirs \
    $JENKINS_HOME/jobs/ $BUILD_ID/jobs/

# Archive & clean
tar czf ${BUILD_ID}.tar.gz $BUILD_ID/
cp ${BUILD_ID}.tar.gz LATEST.tar.gz
rm -rf $BUILD_ID
