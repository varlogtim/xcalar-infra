#!/usr/bin/env bash

# env vars:
#    XLRINFRADIR should be set
# will retrieve all needed files from xlrinfra except following,
# which should be in cwd that CALLS this script, and set up by Jenkins job:
# - xcalar-gui (assumes has xpe's config.js, etc. in it)
# - .imgid (metadata for app.  should be created by Jenkins job)
#    you can create it by running and saving output of getimgid.sh
# - installertarball.tar.gz (has all the dependencies the installer needs)
# also:
# - nwjs binary (on netstore)
# nwjs and xcalar-gui will be being removed in final product
# when the nwjs binaries will be built entirely on Jenkins slave,
# so this is just meantime

set -e

if [ -z "$XLRINFRADIR" ]; then
    echo "XLRINFRADIR should be set to run this script!"
    exit 1
fi

cwd=$(pwd)

APPNAME="XPE.app"

XPEINFRA="$XLRINFRADIR/docker/xpe"

mkdir -p "$APPNAME/Contents/MacOS"
mkdir -p "$APPNAME/Contents/Resources/Bin"
mkdir -p "$APPNAME/Contents/Resources/scripts"
mkdir -p "$APPNAME/Contents/Resources/Data"
mkdir -p "$APPNAME/Contents/Logs"

# app essential metadata
cp "$XPEINFRA/staticfiles/Info.plist" "$APPNAME/Contents"

# add full installer
cd "$APPNAME/Contents/Resources/Data"
bash -x "$XPEINFRA/scripts/createGui.sh" true # after running, 'Installer' dir created
cd "$cwd"
cp installertarball.tar.gz "$APPNAME/Contents/Resources/Data/Installer" # has files needed by local_installer_mac.sh

# add xcalar-gui (config.js and package.json for nwjs should already be present)
cp -r xcalar-gui "$APPNAME/Contents/Resources/Data/"

# add nwjs mac binary on netstore, unzip it in dest then remove the zip
cd "$APPNAME/Contents/Resources/Bin"
curl http://repo.xcalar.net/deps/nwjs-sdk-v0.29.3-osx-x64.zip -O
unzip -aq nwjs-sdk-v0.29.3-osx-x64.zip
rm -r nwjs-sdk-v0.29.3-osx-x64.zip
curl http://repo.xcalar.net/deps/node-v8.11.1-darwin-x64.tar.gz | tar zxf -
cd "$cwd"

# helper scripts
cp "$XPEINFRA/scripts/bringupcontainers.sh" "$APPNAME/Contents/Resources/scripts"
cp "$XPEINFRA/scripts/getimgid.sh" "$APPNAME/Contents/Resources/scripts"
# file to indicate which img is associated with this installer bundle
# so host program will know weather to open installer of main app at launch
# this should have been made by Jenkins job and in cwd
bash "$XPEINFRA/scripts/getimgid.sh" xdpce > .imgid
cp .imgid "$APPNAME/Contents/Resources/Data"

# executable app entrypoint
cp "$XPEINFRA/scripts/XPE" "$APPNAME/Contents/MacOS"
chmod 777 "$APPNAME/Contents/MacOS/XPE"

# zip app
tar -zcf "$APPNAME.tar.gz" "$APPNAME"
