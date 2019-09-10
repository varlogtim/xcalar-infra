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
USER_INSTALL=
INSTALL=0
BUNDLE=0
DEBUG=${DEBUG:-0}
TMPENV=
readonly REQS=requirements.txt

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
     trace $TMPENV/bin/python3 -m pip "$@"
}

do_bundle() {
    deactivate 2> /dev/null || true
    [ $# -gt 0 ] || set -- -r requirements.txt
    TMPENV=$TMPDIR/venv
    python3 -m venv $TMPENV --clear
    source $TMPENV/bin/activate
    pip install -U pip setuptools wheel
    pip download -d ${PACKAGES} "$@"
    pip wheel -w "$WHEELS" --no-index --no-cache-dir --find-links file://${PACKAGES}/ "$@"
}

do_install() {
    [ $# -gt 0 ] || set -- -r requirements.txt
    pip install --no-index --no-cache-dir --find-links file://${DIR}/wheels/ "$@"
}

sha256() {
    shasum -a 256 | cut -d' ' -f1
}

main() {
    local output=${OUTPUT:-bundle.tar}
    declare -a reqs=()

    if [[ $0 =~ bundle ]] || [[ $0 =~ wheel ]]; then
        BUNDLE=1
    elif [[ $0 =~ install ]]; then
        INSTALL=1
    fi

    TMPDIR=$(mktemp -d /tmp/pip.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf $TMPDIR" EXIT

    while [ $# -gt 0 ]; do
        local cmd="$1"
        shift
        case "$cmd" in
            install) INSTALL=1 ;;
            bundle) BUNDLE=1 ;;
            -h | --help) usage; exit 0;;
            -r | --requirements) user_req="$1"; shift ;;
            -i | --install) install_links="$1"; shift;;
            -o | --output) output="$1"; shift ;;
            --) break;;
            *)
                usage >&2
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
        if [ -z "$output" ]; then
            sha1req="$(sha1 < "${req[@]}")"
            output="${req0dir}/${req0file}-${sha256:0:8}.tar"
        fi
        args=''
        do_install $USER_INSTALL -r ${req:-${DIR}/requirements.txt} virtualenv
    elif ((BUNDLE)); then
        PACKAGES=$TMPDIR/packages
        WHEELS=$TMPDIR/wheels
        mkdir -p "$PACKAGES" "$WHEELS"
        info "Building packages from $req ..."
        cp $req $TMPDIR/${REQ}
        cp ${BASH_SOURCE[0]} $TMPDIR/install.sh
        do_bundle -r $req virtualenv
        echo >&2 "Creating $output ..."
        tar caf "${output:-pip-bundler.tar.gz}" --owner=root --group=root -C "${TMPDIR}" install.sh $(basename $req) wheels
        rm -rf $TMPDIR
    fi
}

main "$@"
exit
__PAYLOAD__STARTS__
