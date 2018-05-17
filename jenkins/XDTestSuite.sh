#!/bin/bash

trap '(xclean; kill $(jobs -p)) || true' SIGINT SIGTERM EXIT

export XLRINFRADIR="${XLRINFRADIR:-$XLRDIR/xcalar-infra}"
export XLRGUIDIR="${XLRGUIDIR:-$XLRDIR/xcalar-gui}"
export XCE_LICENSEDIR=$XLRDIR/src/data
export XCE_LICENSEFILE=${XCE_LICENSEDIR}/XcalarLic.key
NUM_USERS=${NUM_USERS:-$(shuf -i 2-3 -n 1)}
TEST_DRIVER_PORT="5909"

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
        for gitsha in $gitshas; do
            git checkout "$gitsha" src/include/libapis/LibApisCommon.h
            versionSig=`md5sum src/include/libapis/LibApisCommon.h | cut -d\  -f 1`
            echo "$gitsha: VersionSig = $versionSig"
            if grep -q "$versionSig" "$XLRGUIDIR/ts/thrift/XcalarApiVersionSignature_types.js"; then
                echo "$gitsha is a match"
                git checkout HEAD src/include/libapis/LibApisCommon.h
                git checkout "$gitsha"
                foundVersion="true"
                break
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

echo "Starting usrnodes"
cd $XLRDIR
export XCE_CONFIG="${XCE_CONFIG:-$XLRDIR/src/bin/usrnode/test-config.cfg}"
launcher.sh 1 daemon

echo "Starting Caddy"
TmpCaddy=`mktemp Caddy.conf.XXXXX`
TmpCaddyLogs=`mktemp CaddyLogs.XXXXX.log`
cp $XLRDIR/conf/Caddyfile "$TmpCaddy"
sed -i -e 's!/var/www/xcalar-gui!'$XLRGUIDIR'/'$GUI_FOLDER'!g' "$TmpCaddy"
echo "Caddy logs at $TmpCaddyLogs"
caddy -conf "$TmpCaddy" >"$TmpCaddyLogs" 2>&1 &
caddyPid=$!
echo "Caddy pid $caddyPid"
sleep 5

echo "Starting test driver"
TmpServerLogs=`mktemp serverLogs.XXXXX.log`
echo "server.py logs available at $TmpServerLogs"
python $XLRGUIDIR/assets/test/testSuitePython/server.py -t localhost >"$TmpServerLogs" 2>&1 &
serverPid=$!
echo "Server.py pid $serverPid"
sleep 5

#THIS IS HOW YOU RUN IT: localhost:8888/unitTest.html?createWorkbook=y&user=test

echo "Running test suites in pseudo terminal"
URL="https://localhost:$TEST_DRIVER_PORT/action?name=start&mode=$MODE&host=localhost&server=localhost&port=$TEST_DRIVER_PORT&users=$NUM_USERS"
HTTP_RESPONSE=$(curl -k --silent --write-out "HTTPSTATUS:%{http_code}" -X GET $URL)
sleep 5

numTries=3
chromeLogsFound="false"
for ii in `seq 1 $numTries`; do
    chromeLogs="`ls -lat /tmp | grep "chromium" | head -n1 | awk '{print $9}'`"
    if [ -f "/tmp/$chromeLogs/chrome_debug.log" ]; then
        chromeLogsFound="true"
        break
    fi
    sleep 5
done

if [ "$chromeLogsFound" = "false" ]; then
    echo "Could not find chrome logs"
    exit 1
fi

echo "chromeLogs at /tmp/$chromeLogs"
tail -f "/tmp/$chromeLogs/chrome_debug.log" &
tailPid=$!

URL="https://localhost:$TEST_DRIVER_PORT/action?name=getstatus"
HTTP_BODY="Still running"
while [ "$HTTP_BODY" == "Still running" ]
do
    echo "Test suite is still running"
    sleep 5
    # store the whole response with the status at the and
    HTTP_RESPONSE=$(curl -k --silent --write-out "HTTPSTATUS:%{http_code}" -X GET $URL)
    # extract the body
    HTTP_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
done
echo "Test suite finishes"
echo "$HTTP_BODY"
echo "Closing test driver"
URL="https://localhost:$TEST_DRIVER_PORT/action?name=close"
HTTP_RESPONSE=$(curl -k --silent --write-out "HTTPSTATUS:%{http_code}" -X GET $URL)

kill $serverPid || true
kill $caddyPid || true
kill $tailPid || true

# Archive chromeLogs
cp /tmp/$chromeLogs/chrome_debug.log .
rm -rf "/tmp/$chromeLogs"

if [[ "$HTTP_BODY" == *"status:fail"* ]]; then
  echo "TEST SUITE FAILED"
  exit 1
else
  echo "TEST SUITE PASS"
  exit 0
fi
