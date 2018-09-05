#!/usr/bin/env bash

# Constructs the Xcalar Design app
# Mac app is just directory with specific directory structure; creates that and
# adds in all required files the app needs to run on the host.

set -e

: "${XLRINFRADIR:?Need to set non-empty XLRINFRADIR}"
: "${GUIBUILD:?Need to set non-empty GUIBUILD (path to built gui to include in app)}"
: "${BUILD_GRAFANA:?Need to set true or false env var BUILD_GRAFANA}"
: "${DEV_BUILD:?Need to set true or false env var DEV_BUILD}"
: "${XCALAR_IMAGE_NAME:?Need to set name of Docker image for .imgid app file, as env var XCALAR_IMAGE_NAME}"
: "${APPOUT:?Need to set non-empty APPOUT (path to app to generate)}"
: "${INSTALLERTARBALL:?Need to set non-empty INSTALLERTARBALL (path to installer tarball)}"

startCwd=$(pwd)
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# make sure app out specified is .app
if [[ ! $APPOUT == *.app ]]; then
    echo "APPOUT must end in .app" >&2
    exit 1
fi
# create app; get basename and full path
if [ -e "$APPOUT" ]; then
    echo "$APPOUT already exists!" >&2
    exit 1
fi
APPBASENAME=$(basename "$APPOUT" .app)
mkdir -p "$APPOUT"
cd "$APPOUT"
APP_ABS_PATH=$(pwd)
cd "$startCwd"

XPEINFRAROOT="$XLRINFRADIR/docker/xpe"

CONTENTS="$APP_ABS_PATH/Contents"
MACOSDIR="$CONTENTS/MacOS"
LOGS="$CONTENTS/Logs"
RESOURCES="$CONTENTS/Resources"
BIN="$RESOURCES/Bin"
APPGUIDIR="$RESOURCES/gui/xcalar-gui"
SCRIPTS="$RESOURCES/scripts"
DATA="$RESOURCES/Data"
INSTALLER="$RESOURCES/Installer"
DMGBIN="$BIN"

# icon to use for the app (must be a .icns file; see general MacOS app icon guidelines)
APPICON_PATH="$GUIBUILD/assets/images/appIcons/AppIcon.icns"

# MacOS apps require a certain structure in the app dir.
# create that here along with other dirs needed specifically for this app
create_app_structure() {
    mkdir -p "$CONTENTS"
    mkdir -p "$MACOSDIR"
    mkdir -p "$LOGS"
    mkdir -p "$RESOURCES"
    mkdir -p "$BIN"
    mkdir -p "$APPGUIDIR"
    mkdir -p "$SCRIPTS"
    mkdir -p "$DATA"
    mkdir -p "$INSTALLER"
}

# MacOS apps require certain metadata; add that essential metadata here
setup_required_app_files() {
    # app essential metadata
    cp "$XPEINFRAROOT/staticfiles/Info.plist" "$CONTENTS"

    # add app entrypoint (executable file in this dir will be run when user
    # double clicks app); must make exeuctable
    # executable MUST be same name as appbase name (mac requirement)
    # so check first if this file is in infra, in case we changed the name of the app
    executablePathInInfra="$XPEINFRAROOT/scripts/$APPBASENAME"
    if [ ! -f "$executablePathInInfra" ]; then
        echo "Can't find executable file in infra repo: $executablePathInInfra \
(The executable file must be the same name as the app, as per MacOS \
requirements.)" >&2
        exit 1
    fi
    cp "$XPEINFRAROOT/scripts/$APPBASENAME" "$MACOSDIR"
    chmod 777 "$MACOSDIR/$APPBASENAME"

    # set app icon
    cp "$APPICON_PATH" "$RESOURCES"
}

# Copies in GUIs and makes modifications required for app
setup_app_gui() {
    cp -r "$GUIBUILD"/* "$APPGUIDIR"

    # config.js so xcalar-gui on host filesystem will communicatee to Xcalar backend in Docker
    cp "$XPEINFRAROOT/staticfiles/config.js" "$APPGUIDIR/assets/js/"
}

setup_installer_assets() {
    # functions called by the xpeServer during install
    cp "$XPEINFRAROOT/scripts/local_installer_mac.sh" "$INSTALLER"
    cp "$INSTALLERTARBALL" "$INSTALLER" # the docker images and other files needed by local_installer_mac.sh
}

setup_nwjs() {
    # setup nwjs
    cd "$BIN"
    curl http://repo.xcalar.net/deps/nwjs-sdk-v0.29.3-osx-x64.zip -O
    unzip -aq nwjs-sdk-v0.29.3-osx-x64.zip
    rm nwjs-sdk-v0.29.3-osx-x64.zip
    # must change app metadata to get customized nwjs menus to display app name
    # http://docs.nwjs.io/en/latest/For%20Users/Advanced/Customize%20Menubar/ <- see MacOS section
    find nwjs-sdk-v0.29.3-osx-x64/nwjs.app/Contents/Resources/*.lproj/InfoPlist.strings -type f -print0 | xargs -0 sed -i 's/CFBundleName\s*=\s*"nwjs"/CFBundleName = "Xcalar Design"/g'
    # replace nwjs default icon with app icon (hack for now, not getting icon attr to work)
    # nwjs icon will dispaly on refresh/quit prompts, even when running Xcalar Design app
    cp "$APPICON_PATH" nwjs-sdk-v0.29.3-osx-x64/nwjs.app/Contents/Resources/app.icns
    cp "$APPICON_PATH" nwjs-sdk-v0.29.3-osx-x64/nwjs.app/Contents/Resources/document.icns

    # add nwjs's package.json (uses as config file on nwjs start)
    cp "$XPEINFRAROOT/staticfiles/package.json" "$APPGUIDIR"
    # nwjs entrypoint specified by the package.json
    mv "$APPGUIDIR/assets/js/xpe/starter.js" "$APPGUIDIR"

    # install npm modules required by nwjs' entrypoint
    # [[- the gui build will not include node_modules dir because everything is
    # intended to be run in browser context, so needed js files are imported
    # via <script> tags in the html rather than required.
    # however, in the app, nwjs will be rooted in the gui build,
    # and its entrypoint is a js file running in node context which must require
    # modules in node context prior to any GUI running.
    # therefore, npm install to get node_modules/<require module> modules for
    # each such 3rd party module the entrypoint requires.
    # (can't use package.json for this - it would need to be shared by both
    # nodejs and nwjs; but package.json for nodejs does not allow capital letters
    # in name field, while nwjs' package.json needs name field to match app's name
    #  (Xcalar Design) else it will generate additional Application Support
    # directories by that name.  So require the modules directly]]
    cd "$APPGUIDIR"
    npm install jquery
}

setup_bin() {
    setup_nwjs
    # nodejs in to Bin directory
    # make sure you are curling directly in to bin dir
    cd "$BIN" # setup_nwjs will change dir
    curl http://repo.xcalar.net/deps/node-v8.11.1-darwin-x64.tar.gz | tar zxf -
}

# hidden files in the MacOS dir are used on the host at install time, to determine
# how the install should be done.
setup_hidden_files() {
    # file to indicate which img is associated with this installer bundle
    # so host program will know weather to open installer of main app at launch
    # this should have been made by Jenkins job and in cwd
    if ! imgsha=$(docker image inspect "$XCALAR_IMAGE_NAME":lastInstall -f '{{ .Id }}' 2>/dev/null); then
        echo "No $XCALAR_IMAGE_NAME:lastInstall to get image sha from!!" >&2
        exit 1
    else
        echo "$imgsha" > "$DATA/.imgid"
    fi

    # if supposed to build grafana, add a mark for this for host-side install
    if $BUILD_GRAFANA; then
        touch "$MACOSDIR/.grafana"
    fi
    # if a dev build (will expose right click feature in GUIs), add a mark for this for host-side install
    if $DEV_BUILD; then
        touch "$MACOSDIR/.dev"
    fi
}

create_app_structure
setup_required_app_files
setup_app_gui # run before setup_bin
setup_installer_assets
setup_bin
setup_hidden_files

# echo for other scripts
echo "$APPOUT"
