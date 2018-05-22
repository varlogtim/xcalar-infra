#!/usr/bin/env bash

#
# if $XLRGUIDIR and $XLRINFRA set, will piece together guis/
# folder for XPE.app (has guis for installer, uninstaller,
# revert tool, and xpeServer)
#

set -e

if [ -z "$XLRGUIDIR" ]; then
    echo "Need to set XLRGUIDIR to run this script!" >&2
    exit 1
fi

if [ -z "$XLRINFRADIR" ]; then
    echo "Need to set XLRINFRADIR to run this script!" >&2
    exit 1
fi

XPEINFRAROOT="$XLRINFRADIR/docker/xpe"

cwd=$(pwd)
GUIROOT="$cwd/xpeGuis"
CSSROOT="$GUIROOT/css"
JSROOT="$GUIROOT/js"
ASSETSROOT="$GUIROOT/assets"
INSTALLROOT="$GUIROOT/Installer"
UNINSTALLROOT="$GUIROOT/Uninstaller"
REVERTROOT="$GUIROOT/Reverter"
SERVERROOT="$GUIROOT/xpeServer"
DOCKERSTARTERROOT="$GUIROOT/DockerStarter"

mkdir -p "$INSTALLROOT" "$UNINSTALLROOT" "$REVERTROOT" "$DOCKERSTARTERROOT" "$SERVERROOT" "$CSSROOT" "$JSROOT" "$ASSETSROOT"

cd "$XLRGUIDIR"
if [ ! -d xcalar-gui ]; then
    make dev
fi

cp "$XLRGUIDIR/xcalar-gui/assets/stylesheets/css/xpe.css" "$CSSROOT"
curl http://repo.xcalar.net/deps/bootstrap.css -o "$CSSROOT/bootstrap.css"
curl http://repo.xcalar.net/deps/googlefonts.css -o "$CSSROOT/googlefonts.css"
# need for Source Code Pro font to work
cp -r "$XLRGUIDIR/3rd/fonts/sourcecodepro" "$CSSROOT"
cp "$XLRGUIDIR/xcalar-gui/3rd/bower_components/jquery/dist/jquery.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/3rd/jquery-ui.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/xpe/xpeCommon.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/xpe/xpeNwjs.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/xpe/xpeInstallClient.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/xpe/xpeUninstallClient.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/xpe/xpeRevertClient.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/xpe/xpeDockerStarter.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/httpStatus.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/promiseHelper.js" "$JSROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/shared/util/xcHelper.js" "$JSROOT"
curl http://netstore/users/jolsen/makeinstaller/xdlogo.png -o "$ASSETSROOT/xdlogo.png"
cp "$XLRGUIDIR/xcalar-gui/assets/images/installer-wave.png" "$ASSETSROOT"
cp -r "$XLRGUIDIR/xcalar-gui/assets/fonts" "$ASSETSROOT"

cp "$XPEINFRAROOT/scripts/local_installer_mac.sh" "$SERVERROOT"
cp -r "$XLRGUIDIR/xcalar-gui/services/xpeServer/." "$SERVERROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/httpStatus.js" "$SERVERROOT"
cp "$XLRGUIDIR/xcalar-gui/assets/js/promiseHelper.js" "$SERVERROOT"

# main html content for the guis

cp "$XLRGUIDIR/xcalar-gui/xpe/xpeInstaller.html" "$INSTALLROOT"
cp "$XPEINFRAROOT/staticfiles/INSTALLER_package.json" "$INSTALLROOT/package.json"
cp "$XLRGUIDIR/xcalar-gui/xpe/xpeUninstaller.html" "$UNINSTALLROOT"
cp "$XPEINFRAROOT/staticfiles/UNINSTALLER_package.json" "$UNINSTALLROOT/package.json"
cp "$XLRGUIDIR/xcalar-gui/xpe/xpeRevertTool.html" "$REVERTROOT"
cp "$XPEINFRAROOT/staticfiles/REVERTER_package.json" "$REVERTROOT/package.json"
cp "$XLRGUIDIR/xcalar-gui/xpe/xpeDockerStarter.html" "$DOCKERSTARTERROOT"
cp "$XPEINFRAROOT/staticfiles/DOCKERSTARTER_package.json" "$DOCKERSTARTERROOT/package.json"

## symlink to root dirs for each of the guis to conform to imports in style.css

addSymLinks() {
    local startCwd=$(pwd)
    cd "$1"
    ln -s "../assets" "assets"
    ln -s "../js" "js"
    ln -s "../css" "css"
    cd "$startCwd"
}
addSymLinks "$INSTALLROOT"
addSymLinks "$UNINSTALLROOT"
addSymLinks "$REVERTROOT"
addSymLinks "$DOCKERSTARTERROOT"

# run npm install on the installer server
cd "$SERVERROOT"
npm install
