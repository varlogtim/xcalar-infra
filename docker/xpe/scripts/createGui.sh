#!/usr/bin/env bash

#
# if $XLRGUIDIR and $XLRINFRA set, will piece together GUI
# folder for XPE.app
# optional arg: true, will do 'grunt dev' on $XLRGUIDIR first
#

set -e

if [ -z "$XLRGUIDIR" ]; then
    echo "Need to set XLRGUIDIR to run this script!"
    exit 1
fi

if [ -z "$XLRINFRADIR" ]; then
    echo "Need to set XLRINFRADIR to run this script!"
    exit 1
fi

XPEINFRAROOT="$XLRINFRADIR/docker/xpe"

cwd=$(pwd)
ROOT="$cwd/Installer"
GUIROOT="$ROOT/gui"
SERVERROOT="$ROOT/xpeInstallerServer"

mkdir -p "$SERVERROOT"
mkdir -p "$GUIROOT"
cd "$GUIROOT"
mkdir -p css assets js

cd "$XLRGUIDIR"
if [ "$1" = true ]; then
    make dev
fi

cp "$XPEINFRAROOT/scripts/local_installer_mac.sh" "$ROOT"
cp "$XPEINFRAROOT/staticfiles/XCEINSTALLER_package.json" "$GUIROOT/package.json"
cp "$XLRGUIDIR/xcalar-gui/xpeInstaller.html" "$GUIROOT"
cp /netstore/users/jolsen/makeinstaller/xpeInstaller.css "$GUIROOT/css"
cp "$XLRGUIDIR/xcalar-gui/assets/stylesheets/css/style.css" "$GUIROOT/css"
curl http://repo.xcalar.net/deps/bootstrap.css -o "$GUIROOT/css/bootstrap.css"
curl http://repo.xcalar.net/deps/googlefonts.css -o "$GUIROOT/css/googlefonts.css"
cp "$XLRGUIDIR/xcalar-gui/3rd/bower_components/jquery/dist/jquery.js" "$GUIROOT/js"
cp "$XLRGUIDIR/xcalar-gui/3rd/jquery-ui.js" "$GUIROOT/js"
cp "$XLRGUIDIR/xcalar-gui/assets/js/xpe/xpeClientJs.js" "$GUIROOT/js"
cp "$XLRGUIDIR/xcalar-gui/assets/js/httpStatus.js" "$GUIROOT/js"
cp "$XLRGUIDIR/xcalar-gui/assets/js/promiseHelper.js" "$GUIROOT/js"
curl http://netstore/users/jolsen/makeinstaller/xdlogo.png -o "$GUIROOT/assets/xdlogo.png"
cp "$XLRGUIDIR/xcalar-gui/assets/images/installer-wave.png" "$GUIROOT/assets"
cp -r "$XLRGUIDIR/xcalar-gui/assets/fonts" "$GUIROOT/assets"
cp -r "$XLRGUIDIR/xcalar-gui/services/xpeInstallerServer/." "$SERVERROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/httpStatus.js" "$SERVERROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/promiseHelper.js" "$SERVERROOT"

# run npm install on the installer server
cd "$SERVERROOT"
npm install

echo "node $SERVERROOT/xpeServer.js"
echo "cd $ROOT/gui"
echo "~/Documents/xpetest/XPE.app/Contents/Resources/Bin/nwjs-sdk-v0.29.3-osx-x64/nwjs.app/Contents/MacOS/nwjs ."
