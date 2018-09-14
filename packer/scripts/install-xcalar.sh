#!/bin/bash

XCE_CONFDIR="${XCE_CONFDIR:-/etc/xcalar}"


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
}

set +e
set -x
if [ -n "$INSTALLER_URL" ]; then
    set +e
    set -x
    INSTALLER_FILE=/tmp/xcalar-installer.sh
    download_file "$INSTALLER_URL" $INSTALLER_FILE
    bash -x "${INSTALLER_FILE}" --nostart
    rc=$?
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
    POSTINSTALL=/tmp/post.sh
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

sed -i '/# Provides:/a# Should-Start: cloud-config' /etc/init.d/xcalar

exit 0
