#!/bin/bash

trap '(xclean; kill $(jobs -p)) || true' SIGINT SIGTERM EXIT

export XLRINFRADIR="${XLRINFRADIR:-$XLRDIR/xcalar-infra}"
export XLRGUIDIR="${XLRGUIDIR:-$XLRDIR/xcalar-gui}"
export XCE_LICENSEDIR=$XLRDIR/src/data
export XCE_LICENSEFILE=${XCE_LICENSEDIR}/XcalarLic.key
NUM_USERS=${NUM_USERS:-$(shuf -i 2-3 -n 1)}
TEST_DRIVER_PORT="5909"

# Make symbolic link
sudo mkdir /var/www || true
sudo ln -sfn $WORKSPACE/xcalar-gui/xcalar-gui /var/www/xcalar-gui

if [ $JOB_NAME = "GerritSQLCompilerTest" ]; then
    cd $XLRGUIDIR
    git diff --name-only HEAD^1 > out
    echo `cat out`
    diffTargetFile=`cat out | grep -E "(assets\/test\/json\/SQLTest.json|assets\/extensions\/ext-available\/sql.ext|ts\/components\/sql\/|ts\/thrift\/XcalarApi.js|ts\/shared\/api\/xiApi.ts|ts\/components\/worksheet\/oppanel\/SQL.*|ts\/XcalarThrift.js|ts\/components\/dag\/node\/.*SQL.*|ts\/components\/dag\/(DagView.ts|DagGraph.ts|DagSubGraph.ts|DagTab.ts|DagTabManager.ts|DagTabSQL.ts))" | grep -v "ts\/components\/sql\/sqlQueryHistoryPanel.ts"`

    rm -rf out

    if [ -n "$diffTargetFile" ] || [ "$RUN_ANYWAY" = "true" ]
    then
        echo "Change detected"
    else
        echo "No target file changed"
        exit 0
    fi
fi

echo "Installing required packages"
if grep -q Ubuntu /etc/os-release; then
    sudo apt-get install -y libnss3-dev chromium-browser
    sudo apt-get install -y libxss1 libappindicator1 libindicator7 libgconf-2-4
    sudo apt-get install -y Xvfb
    if [ ! -f /usr/bin/chromedriver ]; then
        echo "Wget chrome driver"
        wget http://chromedriver.storage.googleapis.com/2.24/chromedriver_linux64.zip
        unzip chromedriver_linux64.zip
        chmod +x chromedriver
        sudo mv chromedriver /usr/bin/
    else
        pwd
        echo "Chrome driver already installed"
    fi
else
    sudo curl -ssL http://repo.xcalar.net/rpm-deps/google-chrome.repo | sudo tee /etc/yum.repos.d/google-chrome.repo
    curl -sSO https://dl.google.com/linux/linux_signing_key.pub
    sudo rpm --import linux_signing_key.pub
    rm linux_signing_key.pub
    sudo yum install -y google-chrome-stable
    sudo yum localinstall -y /netstore/infra/packages/chromedriver-2.34-2.el7.x86_64.rpm
    sudo yum install -y Xvfb
fi

pip install pyvirtualdisplay selenium

if [ "$AUTO_DETECT_XCE" = "true" ]; then
    foundVersion="false"
    echo "Detecting version of XCE to use"
    cd $XLRDIR
    versionSig=`md5sum src/include/libapis/LibApisCommon.h | cut -d\  -f 1`
    if grep -q "$versionSig" "$XLRGUIDIR/ts/thrift/XcalarApiVersionSignature_types.js"; then
        echo "Current version of XCE is compatible"
        foundVersion="true"
    else
        echo "Current version of XCE is not compatible. Trying..."
        gitshas=`git log --format=%H src/include/libapis/LibApisCommon.h`
        prevSha="HEAD"
        for gitsha in $gitshas; do
            git checkout "$gitsha" src/include/libapis/LibApisCommon.h
            versionSig=`md5sum src/include/libapis/LibApisCommon.h | cut -d\  -f 1`
            echo "$gitsha: VersionSig = $versionSig"
            if grep -q "$versionSig" "$XLRGUIDIR/ts/thrift/XcalarApiVersionSignature_types.js"; then
                echo "$gitsha is a match"
                echo "Checking out $prevSha as the last commit with the matching signature"
                git checkout HEAD src/include/libapis/LibApisCommon.h
                git checkout "$prevSha"
                git submodule update --init --recursive xcalar-idl
                foundVersion="true"
                break
            else
                prevSha="$gitsha^1"
            fi
        done
    fi

    if [ "$foundVersion" = "false" ]; then
        echo "Could not find a compatible version of XCE to use"
        exit 1
    fi
fi

echo "Building XCE"
cd $XLRDIR
set +e
source doc/env/xc_aliases
xclean
set -e
cmBuild clean
cmBuild config prod
cmBuild

echo "Building XD"
cd $XLRGUIDIR
make debug PRODUCT="$GUI_PRODUCT"

if [ "$GUI_PRODUCT" = "XI" ]; then
    GUI_FOLDER=xcalar-insight
    echo "Using xcalar-insight"
else
    GUI_FOLDER=xcalar-gui
    echo "Using xcalar-gui"
fi

cd $XLRDIR

mkdir -p src/sqldf/sbt/target
tar --wildcards -xOf /netstore/builds/byJob/BuildSqldf-with-spark-branch/lastSuccessful/archive.tar xcalar-sqldf-*.noarch.rpm | rpm2cpio | cpio --to-stdout -i ./opt/xcalar/lib/xcalar-sqldf.jar >$XLRDIR/src/sqldf/sbt/target/xcalar-sqldf.jar

export NODE_ENV=dev
xc2 cluster start --num-nodes 1

echo "Starting Caddy"
pkill caddy || true
TmpCaddy=`mktemp Caddy.conf.XXXXX`
TmpCaddyLogs=`mktemp CaddyLogs.XXXXX.log`
cp $XLRDIR/conf/Caddyfile "$TmpCaddy"
sed -i -e 's!/var/www/xcalar-gui!'$XLRGUIDIR'/'$GUI_FOLDER'!g' "$TmpCaddy"
# strip out the jwt settings for testing (for now) to allow unauthenticated access
sed -i -e '/jwt {/,/}/d' "$TmpCaddy"
echo "Caddy logs at $TmpCaddyLogs"
caddy -conf "$TmpCaddy" >"$TmpCaddyLogs" 2>&1 &
caddyPid=$!
echo "Caddy pid $caddyPid"
sleep 5

cd $XLRGUIDIR/assets/dev/unitTest
# Please don't ask me why I have to independently install this package.
# This is the only way I've found to make it work.
npm install node-bin-setup
npm install

exitCode=1
echo "Starting test driver"
if  [ $JOB_NAME = "GerritSQLCompilerTest" ]; then
    npm test -- sqlTest https://localhost:8443
elif [ $JOB_NAME = "XDUnitTest" ]; then
    npm test -- unitTest https://localhost:8443
# elif [ $JOB_NAME = "GerritExpServerTest" ]; then
#     npm test -- expServer || true
else
    npm test -- testSuite https://localhost:8443
fi
exitCode=$?

sudo unlink /var/www/xcalar-gui || true
kill $caddyPid || true
xc2 cluster stop

if [ $exitCode -ne "0" ]; then
    mkdir -p /var/log/xcalar/failedLogs || true
    cp -r "/tmp/xce-`id -u`"/* /var/log/xcalar/failedLogs/
    cp $XLRDIR/$TmpCaddyLogs /var/log/xcalar/failedLogs/
fi
exit $exitCode
