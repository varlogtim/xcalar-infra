#!/bin/bash

touch /tmp/${JOB_NAME}_${BUILD_ID}_START_TIME

export XLRDIR=`pwd`
export ExpServerd="false"
export PATH="/opt/clang/bin:$XLRDIR/bin:$PATH"
export CCACHE_BASEDIR=$XLRDIR

source $XLRDIR/doc/env/xc_aliases

genBuildArtifacts() {
    mkdir -p ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
    mkdir -p $XLRDIR/tmpdir

    # Find core files and dump backtrace
    gdbcore.sh -c core.tar.bz2 $XLRDIR tmpdir /var/log/xcalar /var/tmp/xcalar-root

    find /tmp ! -path /tmp -newer /tmp/${JOB_NAME}_${BUILD_ID}_START_TIME 2>/dev/null | xargs cp --parents -rt $XLRDIR/tmpdir/

    PIDS=()
    for dir in tmpdir /var/log/xcalar; do
        if [ -d $dir ]; then
            if [ "$dir" = "/var/log/xcalar" ]; then
                tar -cf var_log_xcalar.tar.bz2 --use-compress-prog=pbzip2 $dir &
            else
                tar -cf $dir.tar.bz2 --use-compress-prog=pbzip2 $dir &
            fi
            PIDS+=($!)
        fi
    done

    wait "${PIDS[@]}"
    ret=$?
    if [ $ret -ne 0 ]; then
        echo >&2 "ERROR($ret): tar failed"
    fi

    for dir in core tmpdir /var/log/xcalar; do
        if [ "$dir" = "/var/log/xcalar" ]; then
            cp var_log_xcalar.tar.bz2 ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
            rm var_log_xcalar.tar.bz2
            rm $dir/*
        else
            if [ -f $dir.tar.bz2 ]; then
                cp $dir.tar.bz2 ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
                rm $dir.tar.bz2
                if [ -d $dir ]; then
                    rm -r $dir/*
                fi
            fi
        fi
    done

    echo >&2 "Build artifacts copied to ${NETSTORE}/${JOB_NAME}/${BUILD_ID}"

    rm /tmp/${JOB_NAME}_${BUILD_ID}_START_TIME
}

trap "genBuildArtifacts" EXIT

xcEnvEnter "$HOME/.local/lib/$JOB_NAME"

rpm -q xcalar && sudo yum remove -y xcalar
sudo rm -rf /opt/xcalar/scripts

pkill -9 gdbserver || true
pkill -9 usrnode || true
pkill -9 childnode || true
pkill -9 xcmgmtd || true
pkill -9 xcmonitor || true

rm -rf /var/tmp/xcalar-`id -un`/* /var/tmp/xcalar-`id -un`/*
mkdir -p /var/tmp/xcalar-`id -un`/sessions /var/tmp/xcalar-`id -un`/sessions
sudo ln -sfn $XLRDIR/src/data/qa /var/tmp/
sudo ln -sfn $XLRDIR/src/data/qa /var/tmp/`id -un`-qa

git clean -fxd >/dev/null

find $XLRDIR -name "core.*" -exec rm --force {} +

set +e
xclean
set -e

ccache -s

# debug build
build clean  >/dev/null
build config  >/dev/null
build CC="ccache gcc" CXX="ccache g++"
ccache -s
build sanitySerial

set +e
xclean
set -e

# prod build
build clean >/dev/null
build prod CC="ccache gcc" CXX="ccache g++"
build sanitySerial
ccache -s
