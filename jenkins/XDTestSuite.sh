#!/bin/bash
set -x

export XLRINFRADIR="${XLRINFRADIR:-$XLRDIR/xcalar-infra}"
export XLRGUIDIR="${XLRGUIDIR:-$XLRDIR/xcalar-gui}"
export XCE_LICENSEDIR=$XLRDIR/src/data
export XCE_LICENSEFILE=${XCE_LICENSEDIR}/XcalarLic.key
NUM_USERS=${NUM_USERS:-$(shuf -i 2-3 -n 1)}
TEST_DRIVER_PORT="5909"
NETSTORE="/netstore/qa/jenkins"

genBuildArtifacts() {
    mkdir -p ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
    mkdir -p $XLRDIR/tmpdir

    # Find core files, dump backtrace & bzip core files into core.tar.bz2
    gdbcore.sh -c core.tar.bz2 $XLRDIR /var/log/xcalar /var/tmp/xcalar-root 2> /dev/null

    if [ -f core.tar.bz2 ]; then
        corefound=1
    else
        corefound=0
    fi

    find /tmp ! -path /tmp -newer /tmp/${JOB_NAME}_${BUILD_ID}_START_TIME 2> /dev/null | xargs cp --parents -rt $XLRDIR/tmpdir/

    taropts="--warning=no-file-changed --warning=no-file-ignored --use-compress-prog=pbzip2"
    PIDS=()
    dirList=(tmpdir /var/log/xcalar /var/opt/xcalar/kvs)
    for dir in ${dirList[*]}; do
        if [ -d $dir ]; then
            case "$dir" in
                "/var/log/xcalar")
                    tar -cf var_log_xcalar.tar.bz2 $taropts $dir > /dev/null 2>&1 & ;;
                "/var/opt/xcalar/kvs")
                    tar -cf var_opt_xcalar_kvs.tar.bz2 $taropts $dir > /dev/null 2>&1 & ;;
                *)
                    tar -cf $dir.tar.bz2 $taropts $dir > /dev/null 2>&1 & ;;
            esac
            PIDS+=($!)
        fi
    done

    wait "${PIDS[@]}"
    local ret=$?
    if [ $ret -ne 0 ]; then
        echo "tar returned non-zero value"
    fi

    for dir in core ${dirList[*]}; do
        case "$dir" in
            "/var/log/xcalar")
                cp var_log_xcalar.tar.bz2 ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
                rm var_log_xcalar.tar.bz2
                rm $dir/* 2> /dev/null
                ;;
            "/var/opt/xcalar/kvs")
                cp var_opt_xcalar_kvs.tar.bz2 ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
                rm var_opt_xcalar_kvs.tar.bz2
                rm $dir/* 2> /dev/null
                ;;
            *)
                if [ -f $dir.tar.bz2 ]; then
                    cp $dir.tar.bz2 ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
                    rm $dir.tar.bz2
                    if [ -d $dir ]; then
                        rm -r $dir/* 2> /dev/null
                    fi
                fi
                ;;
        esac
    done

    return $corefound
}

onExit() {
    local retval=$?
    set +e

    if [[ $retval != 0 ]]
    then
        genBuildArtifacts
        echo "Build artifacts copied to ${NETSTORE}/${JOB_NAME}/${BUILD_ID}"
    fi

    (xclean; kill $(jobs -p))
    exit $retval
}

trap onExit SIGINT SIGTERM EXIT

storeExpServerCodeCoverage() {
    outputDir=/netstore/qa/coverage/${JOB_NAME}/${BUILD_ID}
    mkdir -p "$outputDir"
    covReportDir=$XLRGUIDIR/xcalar-gui/services/expServer/test/report

    if [ -d "$covReportDir" ]; then
        echo "expServer code coverage report copied to ${outputDir}"
        cp -r "$covReportDir"/* "${outputDir}"
    else
        echo "code coverage report folder doesn't exist on ${covReportDir}"
    fi
}

runExpServerIntegrationTest() {
    set +e

    currentDir=$PWD
    local retval=0

    cd $XLRDIR/src/bin/tests/pyTestNew
    testCases=("test_dataflow_service.py" "test_workbooks_new" "test_dfworkbooks_execute.py")

    echo "running integration test for expServer"
    for testCase in "${testCases[@]}"; do
        echo "running test $testCase"
        ./PyTest.sh -k "$testCase"
        local ret=$?
        if [ $ret -ne "0" ]; then
            retval=1
        fi
    done

    cd $currentDir
    set -e
    return $retval
}

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
if [ $JOB_NAME = "GerritExpServerTest" ]; then
    cmBuild qa
else
    cmBuild
fi

echo "Building XD"
cd $XLRGUIDIR

if [ $JOB_NAME = "XDFuncTest" ]; then
    make dev PRODUCT="$GUI_PRODUCT"
else
    make debug PRODUCT="$GUI_PRODUCT"
fi

if [ "$GUI_PRODUCT" = "XI" ]; then
    GUI_FOLDER=xcalar-insight
    echo "Using xcalar-insight"
else
    GUI_FOLDER=xcalar-gui
    echo "Using xcalar-gui"
fi

cd $XLRDIR

mkdir -p src/sqldf/sbt/target
SQLDF_VERSION="$(. ${XLRDIR}/src/3rd/spark/BUILD_ENV; echo $SQLDF_VERSION)"
export SQLDF_VERSION
${XLRDIR}/bin/download-sqldf.sh > $XLRDIR/src/sqldf/sbt/target/xcalar-sqldf.jar

export NODE_ENV=dev
if [ "`xc2 --version`" == "xc2, version 1.4.1" ]; then
    useXc2="false"
    TmpSqlDfLogs=`mktemp SqlDf.XXXXX.log`
    echo "Starting SQLDF"
    # loader.sh expects an existing defaultAdmin.json file to have 600
    # permissions. fix that if the file exists.
    if [ -f "/var/opt/xcalar/config/defaultAdmin.json" ]; then
        chmod 0600 /var/opt/xcalar/config/defaultAdmin.json
    fi

    java -jar $XLRDIR/src/sqldf/sbt/target/xcalar-sqldf.jar >"$TmpSqlDfLogs" 2>&1 &

    echo "Starting usrnodes"
    export XCE_CONFIG="${XCE_CONFIG:-$XLRDIR/src/bin/usrnode/test-config.cfg}"
    launcher.sh 1 daemon
else
    useXc2="true"
    xc2 cluster start --num-nodes 1
fi


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

if [ $JOB_NAME = "XDEndToEndTest" ]; then
    cd $XLRGUIDIR/assets/dev/e2eTest
    npm install
    npm install chromedriver --save-dev
else
    cd $XLRGUIDIR/assets/dev/unitTest
    # Please don't ask me why I have to independently install this package.
    # This is the only way I've found to make it work.
    npm install node-bin-setup
    npm install
fi

exitCode=1
echo "Starting test driver"
if  [ $JOB_NAME = "GerritSQLCompilerTest" ]; then
    npm test -- sqlTest https://localhost:8443
    exitCode=$?
elif [ $JOB_NAME = "XDUnitTest" ]; then
    npm test -- unitTest https://localhost:8443
    exitCode=$?
elif [ $JOB_NAME = "GerritExpServerTest" ]; then
    npm test -- expServer https://localhost:8443
    exitCode=$?
    if [ "$STORE_COVERAGE" = "true" ]; then
        storeExpServerCodeCoverage
    fi
    if [ $exitCode = "0" ]; then
        runExpServerIntegrationTest
        exitCode=$?
    fi
elif [ $JOB_NAME = "GerritXcrpcIntegrationTest" ]; then
    npm test -- xcrpcTest https://localhost:8443
    exitCode=$?
elif [ $JOB_NAME = "XDTestSuite" ]; then
    npm test -- testSuite https://localhost:8443
    exitCode=$?
elif [ $JOB_NAME = "XDEndToEndTest" ]; then
    npm test -- --tag "allTests" --env jenkins
    exitCode=$?
elif [ $JOB_NAME = "XDFuncTest" ]; then
    npm test -- XDFuncTest https://localhost:8443 $NUM_USERS $ITERATIONS
    exitCode=$?
fi


sudo unlink /var/www/xcalar-gui || true
kill $caddyPid || true
if [ "$useXc2" == "true" ]; then
    xc2 cluster stop
fi


if [ $exitCode -ne "0" ]; then
    mkdir -p /var/log/xcalar/failedLogs || true
    if [ "$useXc2" == "true" ]; then
        cp -r "/tmp/xce-`id -u`"/* /var/log/xcalar/failedLogs/
    else
        cp $XLRDIR/$TmpSqlDfLogs /var/log/xcalar/failedLogs/
    fi
    cp $XLRDIR/$TmpCaddyLogs /var/log/xcalar/failedLogs/
fi
exit $exitCode
