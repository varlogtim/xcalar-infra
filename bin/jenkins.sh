#!/bin/bash


# Common set up
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XLRINFRADIR="$(cd "$DIR/.." && pwd)"
export PATH=$XLRINFRADIR/bin:$PATH:/opt/xcalar/bin

export PYCURL_SSL_LIBRARY=openssl
export LDFLAGS=-L/usr/local/opt/openssl/lib
export CPPFLAGS=-I/usr/local/opt/openssl/include

cd $XLRINFRADIR || exit 1

#rm -rf .venv
test -e .venv || /opt/xcalar/bin/virtualenv .venv
.venv/bin/pip install -q -r frozen.txt
source .venv/bin/activate
source $XLRINFRADIR/bin/infra-sh-lib
source $XLRINFRADIR/azure/azure-sh-lib
source $XLRINFRADIR/aws/aws-sh-lib

if [ -z "$XLRDIR" ] && [ -e doc/env/xc_aliases ]; then
    export XLRDIR=$PWD
fi

if [ -n "$XLRDIR" ]; then
    . doc/env/xc_aliases
    if ! xcEnvEnter "$HOME/.local/lib/$JOB_NAME"; then
        exit 1
    fi
    setup_proxy
fi

source $XLRINFRADIR/bin/infra-sh-lib

# First look in local (Xcalar) repo for a script and fall back to the one in xcalar-infra
for SCRIPT in "${XLRINFRADIR}/jenkins/${JOB_NAME}.sh"; do
    if test -x "$SCRIPT"; then
        break
    fi
done

if ! test -x "${SCRIPT}"; then
    echo >&2 "No jenkins script for for $JOB_NAME"
    exit 1
fi

"$SCRIPT" "$@"
ret=$?

exit $ret
