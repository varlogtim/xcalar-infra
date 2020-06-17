#!/bin/bash

set -ex

install_pip_bundle() {
    MYTEMP=$(mktemp -d -t bundle.XXXXXX)
    cd "$MYTEMP"
    curl -fsSL "${PIP_BUNDLE_URL}" | tar zxvf -
    export PATH=/opt/xcalar/bin:$PATH
    bash -x install.sh --pip /opt/xcalar/bin/pip3 --python /opt/xcalar/bin/python3
    cd -
    rm -rf "$MYTEMP"
}


install_pip_bundle
