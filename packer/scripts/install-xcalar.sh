#!/bin/bash

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin:/opt/aws/bin:$HOME/bin

XCE_CONFDIR="${XCE_CONFDIR:-/etc/xcalar}"

if [ -z "$TMPDIR" ]; then
    if [ -e /ephemeral/data ]; then
        export TMPDIR=/ephemeral/data/tmp
    elif [ -e /mnt/resource ]; then
        export TMPDIR=/mnt/resource/tmp
    elif [ -e /mnt ]; then
        export TMPDIR=/mnt/tmp
    else
        export TMPDIR=/tmp/installer
    fi
    mkdir -m 1777 -p $TMPDIR
fi

download_file() {
    if [[ $1 =~ ^s3:// ]]; then
        aws s3 cp $1 $2
    else
        curl -fsSL "${1}" -o "${2}"
    fi
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo >&2 "!!! FAILED TO DOWNLOAD $1 !!!"
        echo >&2 "!!! $1 -> $2"
        echo >&2 "!!! rc=$rc"
    fi
    return $rc
}

aws_s3_from_url() {
    local clean_url="$(echo "$1" | sed -e 's/\?.*$//g')"
    clean_url="${clean_url#https://}"
    if ! [[ $clean_url =~ ^s3 ]]; then
        return 1
    fi
    echo "s3://${clean_url#*/}"
}

set +e
set -x
if [ -n "$INSTALLER_URL" ]; then
    set +e
    set -x
    INSTALLER_FILE=$TMPDIR/xcalar-installer.sh
    if [[ $INSTALLER_URL =~ ^s3:// ]]; then
        if ! aws s3 cp $INSTALLER_URL $INSTALLER_FILE; then
            rm -f $INSTALLER_FILE
        fi
    elif INSTALLER_S3=$(aws_s3_from_url "$INSTALLER_URL") && [ -n "$INSTALLER_S3" ]; then
        if ! aws s3 cp $INSTALLER_S3 $INSTALLER_FILE; then
            rm -f $INSTALLER_FILE
        fi
    fi
    test -f $INSTALLER_FILE || download_file "$INSTALLER_URL" $INSTALLER_FILE
    rc=$?
    if [ $rc -eq 0 ]; then
        bash -x "${INSTALLER_FILE}" --nostart
        rc=$?
    fi
    if [ $rc -ne 0 ]; then
        echo >&2 "!!! FAILED TO RUN INSTALLER !!!"
        echo >&2 "!!! $INSTALLER_URL -> $INSTALLER_FILE"
        echo >&2 "!!! rc=$rc"
        env >&2
        exit $rc
    fi
    rm -v -f "${INSTALLER_FILE}"
fi

if [ -n "$LICENSE_URL" ]; then
    set +e
    set -x
    LICENSE_FILE="${XCE_CONFDIR}/XcalarLic.key"
    curl -fsSL "${LICENSE_URL}" -o "${LICENSE_URL}"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo >&2 "!!! FAILED TO DOWNLOAD LICENSE !!!"
        echo >&2 "!!! $LICENSE_URL -> $LICENSE_FILE"
        echo >&2 "!!! rc=$rc"
        env >&2
        exit $rc
    fi
fi

set +e
set -x
if [ -n "$POSTINSTALL_URL" ]; then
    POSTINSTALL=$TMPDIR/post.sh
    download_file "${POSTINSTALL_URL}" "${POSTINSTALL}"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo >&2 "!!! FAILED TO DOWNLOAD POSTINSTALL SCRIPT!!!"
        echo >&2 "!!! $POSTINSTALL_URL -> $POSTINSTALL"
        echo >&2 "!!! rc=$rc"
        env >&2
        exit $rc
    fi
fi
if [ -n "${POSTINSTALL}" ]; then
    bash -x "${POSTINSTALL}" "$@"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo >&2 "!!! FAILED TO RUN POSTINSTALL SCRIPT!!!"
        echo >&2 "!!! $POSTINSTALL $*"
        echo >&2 "!!! rc=$rc"
        env >&2
        exit $rc
    fi
fi

sed -i '/# Provides:/a# Should-Start: cloud-final' /etc/init.d/xcalar

exit 0
