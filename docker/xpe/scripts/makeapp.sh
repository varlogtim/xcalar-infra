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

: "${XLRINFRADIR:?Need to set non-empty XLRINFRADIR}"
: "${XLRGUIDIR:?Need to set non-empty XLRGUIDIR}"
: "${BUILD_GRAFANA:?Need to set true or false env var BUILD_GRAFANA}"
: "${DEV_BUILD:?Need to set true or false env var DEV_BUILD}"
: "${XCALAR_IMAGE_NAME:?Need to set name of Docker image for .imgid app file, as env var XCALAR_IMAGE_NAME}"

cwd=$(pwd)

APPBASENAME="Xcalar Design"
APPNAME="${APPBASENAME}.app"
DMGNAME="${APPBASENAME}.dmg"
EXECUTABLENAME="Xcalar Design"

XPEINFRAROOT="$XLRINFRADIR/docker/xpe"

mkdir -p "$APPNAME/Contents/MacOS"
mkdir -p "$APPNAME/Contents/Resources/Bin"
mkdir -p "$APPNAME/Contents/Resources/scripts"
mkdir -p "$APPNAME/Contents/Resources/guis"
mkdir -p "$APPNAME/Contents/Resources/Data"
mkdir -p "$APPNAME/Contents/Logs"

# app essential metadata
cp "$XPEINFRAROOT/staticfiles/Info.plist" "$APPNAME/Contents"

# add icon; must be in Resources
# if xcalar-gui not built, build it and get icon from there
if [ ! -d "$XLRGUIDIR/xcalar-gui" ]; then
    cd "$XLRGUIDIR"
    make dev
    cd "$cwd"
fi
cp "$XLRGUIDIR/xcalar-gui/assets/images/appIcons/AppIcon.icns" "$APPNAME/Contents/Resources"

# add full installer
cd "$APPNAME/Contents/Resources/guis"
bash -x "$XPEINFRAROOT/scripts/createGui.sh" true # after running, 'xpeGuis' dir created
cd "$cwd"
cp installertarball.tar.gz "$APPNAME/Contents/Resources/guis/xpeGuis/xpeServer" # has files needed by local_installer_mac.sh

# add xcalar-gui (config.js and package.json for nwjs should already be present)
#cp -r xcalar-gui "$APPNAME/Contents/Resources/guis"
tar xzf /netstore/users/jolsen/xcalar-gui.tar.gz -C "$APPNAME/Contents/Resources/guis" ### AMIT:: This a temporary hack for my testing

# setup nwjs
cd "$APPNAME/Contents/Resources/Bin"
curl http://repo.xcalar.net/deps/nwjs-sdk-v0.29.3-osx-x64.zip -O
unzip -aq nwjs-sdk-v0.29.3-osx-x64.zip
rm nwjs-sdk-v0.29.3-osx-x64.zip
# must change app metadata to get customized nwjs menus to display app name
# http://docs.nwjs.io/en/latest/For%20Users/Advanced/Customize%20Menubar/ <- see MacOS section
find nwjs-sdk-v0.29.3-osx-x64/nwjs.app/Contents/Resources/*.lproj/InfoPlist.strings -type f -print0 | xargs -0 sed -i 's/CFBundleName\s*=\s*"nwjs"/CFBundleName = "Xcalar Design"/g'
# replace nwjs default icon with app icon (hack for now, not getting icon attr to work)
# nwjs icon will dispaly on refresh/quit prompts, even when running Xcalar Design app
cp "$XLRGUIDIR/xcalar-gui/assets/images/appIcons/AppIcon.icns" nwjs-sdk-v0.29.3-osx-x64/nwjs.app/Contents/Resources/app.icns
cp "$XLRGUIDIR/xcalar-gui/assets/images/appIcons/AppIcon.icns" nwjs-sdk-v0.29.3-osx-x64/nwjs.app/Contents/Resources/document.icns

# nodejs in to Bin directory
curl http://repo.xcalar.net/deps/node-v8.11.1-darwin-x64.tar.gz | tar zxf -
cd "$cwd"

# file to indicate which img is associated with this installer bundle
# so host program will know weather to open installer of main app at launch
# this should have been made by Jenkins job and in cwd
if ! imgsha=$(docker image inspect $XCALAR_IMAGE_NAME:lastInstall -f '{{ .Id }}' 2>/dev/null); then
    echo "No $XCALAR_IMAGE_NAME:lastInstall to get image sha from!!" >&2
    exit 1
else
    echo "$imgsha" > "$APPNAME/Contents/Resources/Data/.imgid"
fi

# executable app entrypoint
cp "$XPEINFRAROOT/scripts/$EXECUTABLENAME" "$APPNAME/Contents/MacOS"
chmod 777 "$APPNAME/Contents/MacOS/$EXECUTABLENAME"

# if supposed to build grafana, add a mark for this for host-side install
if $BUILD_GRAFANA; then
    touch "$APPNAME/Contents/MacOS/.grafana"
fi
# if a dev build (will expose right click feature in GUIs), add a mark for this for host-side install
if $DEV_BUILD; then
    touch "$APPNAME/Contents/MacOS/.dev"
fi

# zip app
tar -zcf "$APPNAME.tar.gz" "$APPNAME"
