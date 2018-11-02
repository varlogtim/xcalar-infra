#!/bin/bash
#
# Based on Arch pacman/pkgbuild, and very similar to
# how an RPM spec works. The data is defined externally
# in a spec-like looking shell script. This driver program
# is the responsible for doing all the common functions
# (like downloading the source, unpacking, etc) and finally
# calling fpm.

die() {
    echo >&2 "$1"
    exit 1
}

debug() {
    if ((DEBIG)); then
        echo >&2 "debug: $*"
    fi
    "$@"
}

prepare() {
    #cd "$pkgname-$pkgver"
    #patch -p1 -i "$srcdir/$pkgname-$pkgver.patch"
    true
}

build() {
    #cd "$pkgname-$pkgver"
    #./configure --prefix=/usr
    #make
    true
}

check() {
    #cd "$pkgname-$pkgver"
    #make -k check
    true
}

pkgusage() {
    cat <<-EOF
	usage: $0 [-b|--build PKGBUILD] [-d|--debug] [-h|--help]
	Build an rpm/deb package from a PKGBUILD definition
	EOF
}

pkgmain() {
    PKGBUILD="${PKGBUILD:-PKGBUILD}"
    while [ $# -gt 0 ]; do
        local cmd="$1"
        shift
        case "$cmd" in
        -d | --debug) DEBUG=1 ;;
        -b | --build)
            PKGBUILD="$1"
            shift
            ;;
        -h | --help) pkgusage ;;
        *) die "Unknown command: $cmd" ;;
        esac
    done
    if ! test -e "$PKGBUILD"; then
        die "PKGBUILD must be specified"
    fi

    . $PKGBUILD

    TMPDIR="${TMPDIR:-/tmp}/pkgbuild-$(id -u)/$pkgname"
    pkgdir="${TMPDIR}/rootfs"
    rm -rf $TMPDIR
    mkdir -p $pkgdir

    curl -LO "$source"

    if type -t prepare > /dev/null; then
        prepare
    fi
    if type -t build > /dev/null; then
        build
    fi
    if type -t check > /dev/null; then
        check
    fi
    if type -t package > /dev/null; then
        package
    fi
    for dist in rpm deb; do
        fpm -s dir -t $dist \
            --name ${pkgname} \
            --version ${pkgver} \
            ${pkgrel+--iteration $pkgrel} \
            ${license+--license "$license"} \
            --description "${pkgdesc}" \
            --url "${url}" \
            -f -C "$pkgdir"
    done
    rm -rf $TMPDIR
}

pkgmain "$@"
