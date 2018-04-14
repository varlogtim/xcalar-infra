#!/usr/bin/env bash

# env vars:
#	XLRINFRADIR, XLRGUIDIR, and XLRDIR should be set
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
mkdir -p "$APPNAME/Contents/Resources/Data/Installer/gui/assets"
mkdir -p "$APPNAME/Contents/Resources/Data/Installer/gui/css"
mkdir -p "$APPNAME/Contents/Resources/Data/Installer/gui/js"
cp "$XLRGUIDIR/site/xpeInstaller.html" "$APPNAME/Contents/Resources/Data/Installer/gui/" # html
cp "$XPEINFRA/staticfiles/XCEINSTALLER_package.json" "$APPNAME/Contents/Resources/Data/Installer/gui/package.json" # package.json used by nwjs for installer
cp -r "$XLRGUIDIR/3rd/bower_components/jquery/dist/jquery.js" "$APPNAME/Contents/Resources/Data/Installer/gui/js" # js
curl http://netstore/users/jolsen/xpeassets/w3.css -o "$APPNAME/Contents/Resources/Data/Installer/gui/css/w3.css" # css
curl http://netstore/users/jolsen/xpeassets/googlefonts.css -o "$APPNAME/Contents/Resources/Data/Installer/gui/css/googlefonts.css" # css
# once xcalar-gui component checked in, get css from that; until then keep on netstore
# else will need to build the prototype xcalar-gui just to get that one file!
#cp "$XLRGUIDIR/assets/stylesheets/css/xcalarce.css" "$APPNAME/Contents/Resources/Data/Installer/gui/css/divs.css"
curl http://netstore/users/jolsen/xpeassets/updatedcode/xpeinstaller.css -o "$APPNAME/Contents/Resources/Data/Installer/gui/css/xpeinstaller.css" # css
#cp "$XLRGUIDIR/assets/js/installer/xpejs.js" "$APPNAME/Contents/Resources/Data/Installer/gui/js/"
curl http://netstore/users/jolsen/xpeassets/updatedcode/xpejs.js -o "$APPNAME/Contents/Resources/Data/Installer/gui/js/xpejs.js"
cp -a "$XLRGUIDIR/assets/images/xcalarCE/." "$APPNAME/Contents/Resources/Data/Installer/gui/assets/" # images
cp "$XPEINFRA/scripts/local_installer_mac.sh" "$APPNAME/Contents/Resources/Data/Installer" # call by the server apis
cp installertarball.tar.gz "$APPNAME/Contents/Resources/Data/Installer" # has files needed by local_installer_mac.sh

cd "$APPNAME/Contents/Resources/Data/Installer/gui/assets"
curl http://netstore/users/jolsen/bootstrap-3.3.7-dist.tar.gz -o bootstrap-3.3.7-dist.tar.gz
tar xvzf bootstrap-3.3.7-dist.tar.gz
rm bootstrap-3.3.7-dist.tar.gz
cd "$cwd"

# get server for the installer gui and run npm install in it
mkdir -p "$APPNAME/Contents/Resources/Data/Installer/server"
cd "$APPNAME/Contents/Resources/Data/Installer/server"
cp -a "$XLRGUIDIR/services/xceInstallerServer/." .
npm install
cd "$cwd"

# add xcalar-gui (config.js and package.json for nwjs should already be present)
cp -r xcalar-gui "$APPNAME/Contents/Resources/Data/"

# add nwjs mac binary on netstore, unzip it in dest then remove the zip
cd "$APPNAME/Contents/Resources/Bin"
curl http://netstore/users/jolsen/nwjs-sdk-v0.29.3-osx-x64.zip -o nwjs-sdk-v0.29.3-osx-x64.zip 
unzip -a nwjs-sdk-v0.29.3-osx-x64.zip
rm -r nwjs-sdk-v0.29.3-osx-x64.zip
curl http://netstore/users/jolsen/node-v8.11.1-darwin-x64.tar.gz -o node-v8.11.1-darwin-x64.tar.gz
tar xvzf node-v8.11.1-darwin-x64.tar.gz
rm node-v8.11.1-darwin-x64.tar.gz
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
tar -zcvf "$APPNAME.tar.gz" "$APPNAME"
