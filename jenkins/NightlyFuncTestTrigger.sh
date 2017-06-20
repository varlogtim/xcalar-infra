#!/bin/bash

echo "Nightly functional test triggered on `date`"
SYMLINK="`dirname $INSTALLER_PATH`"/"`readlink $INSTALLER_PATH`"
FULL_INSTALLER_PATH=`realpath $SYMLINK`
echo "Preparing to run tests on $FULL_INSTALLER_PATH on $Node"
echo "FULL_INSTALLER_PATH=$FULL_INSTALLER_PATH" > jenkins.properties
