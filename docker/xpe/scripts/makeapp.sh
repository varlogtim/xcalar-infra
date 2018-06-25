#!/usr/bin/env bash

# Constructs the actual Xcalar Design app directory by piecing together files
# from the various repos
#
# optional arg forces build of xcalar-gui project ($XLRGUIDIR)

set -e

: "${XLRINFRADIR:?Need to set non-empty XLRINFRADIR}"
: "${XLRGUIDIR:?Need to set non-empty XLRGUIDIR}"
: "${BUILD_GRAFANA:?Need to set true or false env var BUILD_GRAFANA}"
: "${DEV_BUILD:?Need to set true or false env var DEV_BUILD}"
: "${XCALAR_IMAGE_NAME:?Need to set name of Docker image for .imgid app file, as env var XCALAR_IMAGE_NAME}"

startCwd=$(pwd)

APPBASENAME="Xcalar Design"
APPNAME="${APPBASENAME}.app"
DMGNAME="${APPBASENAME}.dmg"
EXECUTABLENAME="Xcalar Design"

XPEINFRAROOT="$XLRINFRADIR/docker/xpe"

# create base app dir at cwd and get its full path
mkdir -p "$APPNAME"
cd "$APPNAME"
APPPATH=$(pwd)

mkdir -p "$APPPATH/Contents/MacOS"
mkdir -p "$APPPATH/Contents/Resources/Bin"
mkdir -p "$APPPATH/Contents/Resources/Installer"
mkdir -p "$APPPATH/Contents/Resources/scripts"
mkdir -p "$APPPATH/Contents/Resources/Data"
mkdir -p "$APPPATH/Contents/Logs"
APPGUIDIR="$APPPATH/Contents/Resources/gui/xcalar-gui"
mkdir -p "$APPGUIDIR"

# if xcalar-gui not built, build it
if [ ! -d "$XLRGUIDIR/xcalar-gui" ] || [ "$1" ]; then
    cd "$XLRGUIDIR"
#    git submodule update --init
#    git submodule update
#    npm install --save-dev
#    node_modules/grunt/bin/grunt init
#    node_modules/grunt/bin/grunt dev
    make dev # once submodule update in Jenkins resolved, remove this in favor of all the other comments lines (see targui.sh)
    cd "$startCwd"
fi

# app essential metadata
cp "$XPEINFRAROOT/staticfiles/Info.plist" "$APPPATH/Contents"

# add xcalar-gui (config.js and package.json for nwjs should already be present)
tar xzf /netstore/users/jolsen/xcalar-gui.tar.gz -C "$APPPATH/Contents/Resources/gui" ### AMIT:: This a temporary hack for my testing
#cp -r "$XLRGUIDIR/xcalar-gui/"* "$APPGUIDIR" # use this once git submodule update in Jenkins resolved

# build the xpe server
# put back in once figured out the git submodule update in jenkins issue
#cd "$APPGUIDIR/services/xpeServer"
#npm install
#cd "$startCwd"

# add the nwjs javascript entrypoint to the gui root
mv "$APPGUIDIR/assets/js/xpe/starter.js" "$APPGUIDIR"
# nwjs's package.json for xcalar-gui dir
# config.js for letting xcalar-gui on the host machine communicate in to Docker for Xcalar backend
cp "$XPEINFRAROOT/staticfiles/package.json" "$APPGUIDIR"
cp "$XPEINFRAROOT/staticfiles/config.js" "$APPGUIDIR/assets/js/"

# the built xcalar-gui project, will not include node_modules
# because everything is intended to be run in browser context, so needed js files
# are imported via <script> tags in the html
# however, nwjs is rooting at xcalar-gui, and entrypoint is a js running in node context,
# which will need to require files in node context, before any GUI runs.
# therefore, need node_modules/<require module> modules, to get those js files.
# normally could just add in the package.json, but package.json would need to be
# shared by both nodejs (for npm install) and nwjs (to open gui);
# package.json for nodejs does not allow capital letters in name field, but
# nwjs' package.json needs name field to match app's name (Xcalar Design) else it
# will generate additional Application Support directories by that name.
# since right now only need one module - jquery - (for doing Deferreds)
# just go ahead and npm install it
# later if more needed, create a separate package.json
cd "$APPGUIDIR"
npm install jquery
cd "$startCwd"

# a few missing files
curl http://repo.xcalar.net/deps/bootstrap.css -o "$APPGUIDIR/3rd/bootstrap.css"
curl http://repo.xcalar.net/deps/googlefonts.css -o "$APPGUIDIR/3rd/googlefonts.css"
curl http://netstore/users/jolsen/makeinstaller/xdlogo.png -o "$APPGUIDIR/assets/images/xdlogo.png"

# installer assets
cp "$XPEINFRAROOT/scripts/local_installer_mac.sh" "$APPPATH/Contents/Resources/Installer"
cp installertarball.tar.gz "$APPPATH/Contents/Resources/Installer" # has files needed by local_installer_mac.sh

# setup nwjs
cd "$APPPATH/Contents/Resources/Bin"
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
cd "$startCwd"

# file to indicate which img is associated with this installer bundle
# so host program will know weather to open installer of main app at launch
# this should have been made by Jenkins job and in cwd
if ! imgsha=$(docker image inspect "$XCALAR_IMAGE_NAME":lastInstall -f '{{ .Id }}' 2>/dev/null); then
    echo "No $XCALAR_IMAGE_NAME:lastInstall to get image sha from!!" >&2
    exit 1
else
    echo "$imgsha" > "$APPPATH/Contents/Resources/Data/.imgid"
fi

# executable app entrypoint
cp "$XPEINFRAROOT/scripts/$EXECUTABLENAME" "$APPPATH/Contents/MacOS"
chmod 777 "$APPPATH/Contents/MacOS/$EXECUTABLENAME"

# if supposed to build grafana, add a mark for this for host-side install
if $BUILD_GRAFANA; then
    touch "$APPPATH/Contents/MacOS/.grafana"
fi
# if a dev build (will expose right click feature in GUIs), add a mark for this for host-side install
if $DEV_BUILD; then
    touch "$APPPATH/Contents/MacOS/.dev"
fi

# set app icon
cp "$XLRGUIDIR/xcalar-gui/assets/images/appIcons/AppIcon.icns" "$APPPATH/Contents/Resources"

# zip app
cd "$startCwd"
tar -zcf "$APPNAME.tar.gz" "$APPNAME"
