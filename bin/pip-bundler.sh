#!/bin/bash
#
# Use
#   $ ./pip-bundler.sh bundle [-o output.tar.gz] [--] <pip-commands ...>
#
# To generate a bunlde containing the packages fetched
# from the command. Eg, ./INSTALL.sh bundle -r requirements.txt
# will bundle all the packages into wheel.zip, including
# this same script that can be called "on the other side" to
# ./myreq/install.sh install -r requirements.txt


set -eu

DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
USER_INSTALL=""
INSTALL=0
BUNDLE=0
DEBUG=${DEBUG:-0}

say() {
    echo >&2 "$@"
}

trace() {
    if ((DEBUG)); then
        say "debug:" "$@"
    fi
    eval "$@"
}

info() {
    say "info: $*"
}

die() {
    local rc=1
    if [ $# -gt 1 ]; then
        rc="$1"
        shift
    fi
    say "ERROR: $*"
    exit $rc
}

pip() {
     trace $VIRTUAL_ENV/bin/python -m pip "$@"
}

do_bundle() {
    deactivate 2> /dev/null || true
    ARGS=()
    if [ $# -eq 0 ]; then
        if test -e requirements.txt; then
            ARGS+=(-r requirements.txt)
        fi
        if test -e constraints.txt; then
            ARGS+=(-c constraints.txt);
        fi
    fi
    if test -d /netstore/infra; then
        ARGS+=(--find-links file:///netstore/infra/wheels --trusted-host netstore)
    fi

    deactivate 2>/dev/null || true
    VIRTUAL_ENV=$TMPDIR/venv
    /opt/xcalar/bin/python3.6 -m venv $VIRTUAL_ENV --clear
    pip install -U pip setuptools wheel
    pip wheel -w "$WHEELS" "${ARGS[@]}" pip setuptools wheel
    pip wheel -w "$WHEELS" "${ARGS[@]}" "$@"
}

do_install() {
    pip install --no-index --no-cache-dir --find-links file://${DIR}/wheels/ "$@"
}

sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

main() {
    local output=''

    if [[ $0 =~ bundle ]] || [[ $0 =~ wheel ]]; then
        BUNDLE=1
    elif [[ $0 =~ install ]]; then
        INSTALL=1
    fi

    export TMPDIR="${TMPDIR:-/tmp/pip-bundle-$(id -u)}"
    # shellcheck disable=SC2064
    mkdir -p $TMPDIR/wheels $TMPDIR/cache
    rm -rf $TMPDIR/venv

    req='requirements.txt'
    con='constraints.txt'
    output='pip-bundler.tar.gz'
    while [ $# -gt 0 ]; do
        local cmd="$1"
        shift
        case "$cmd" in
            install) INSTALL=1 ;;
            bundle) BUNDLE=1 ;;
            -h | --help) usage; exit 0;;
            -r | --requirements) req="$1"; shift ;;
            -c | --constraints) con="$1"; shift;;
            -i | --install) install_links="$1"; shift;;
            -o | --output) output="$1"; shift ;;
            --) break;;
            *) usage >&2
               die 2 "Unknown command: $cmd"
               ;;
        esac
    done

    if [ $((BUNDLE + INSTALL)) != 1 ]; then
        die 2 "Must specify 'bundle' or 'INSTALL'"
    fi

    if ((INSTALL)); then
        if [ -n "${VIRTUAL_ENV:-}" ] || [ $(id -u) -eq 0 ]; then
            USER_INSTALL=''
        else
            USER_INSTALL='--user'
        fi
        do_install $USER_INSTALL -U pip -c ${con}
        do_install $USER_INSTALL -r ${req} -c ${con} virtualenv
    elif ((BUNDLE)); then
        PACKAGES=$TMPDIR/packages
        WHEELS=$TMPDIR/wheels
        mkdir -p "$PACKAGES" "$WHEELS"
        info "Building packages from $req ..."
        #----
        cp ${BASH_SOURCE[0]} $TMPDIR/install.sh
        sort $req > $TMPDIR/requirements.txt
        if [ -e "$con" ]; then cp $con $TMPDIR/constraints.txt; fi
        do_bundle -r $TMPDIR/requirements.txt -c ${TMPDIR}/constraints.txt
        echo >&2 "Creating $output ..."
        tar caf "$output" --owner=root --group=root -C "${TMPDIR}" install.sh requirements.txt constraints.txt wheels
    fi
}

main "$@"
exit
__PAYLOAD__STARTS__
