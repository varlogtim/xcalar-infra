#!/bin/bash
#
# Based on Arch pacman/pkgbuild, and very similar to
# how an RPM spec works. The data is defined externally
# in a spec-like looking shell script. This driver program
# is the responsible for doing all the common functions
# (like downloading the source, unpacking, etc) and finally
# calling fpm.

DEBUG=${DEBUG:-0}
NOW=$(date +%s)
FORCE=false
CLEAN=true
fpmextra=()
#PREFIX=/usr

die() {
    echo >&2 "$1"
    exit 1
}

debug() {
    if [ "$DEBUG" = "1" ]; then
        echo >&2 "pkgbuild: debug: $*"
    fi
}

run() {
    if [ "$DEBUG" = "1" ]; then
        echo >&2 "pkgbuild: run: $*"
    fi
    "$@"
}

info() {
    echo >&2 "pkgbuild: info: $1"
}

say() {
    echo >&2 "pkgbuild: $1"
}

prepare() {
    if [ -d "$pkgname-$pkgver" ]; then
        cd "$pkgname-$pkgver"
    fi
    local patch_file
    for patch_file in $(ls $srcdir/*.patch $PKGBUILDdir/*.patch 2> /dev/null || true); do
        patch -p1 -i "$patch_file"
    done
    true
}

build() {
    debug "source: $source"
    debug "sources ${sources[*]}"
    if [ -z "$source" ]; then
        source="${sources[0]}"
    fi

    export PREFIX=${prefix:-/usr}

    debug "ls -al: $(ls -al)"
    if [ -d "$srcpkgdir" ]; then
        run cd "$srcpkgdir"
    fi
    if [ -e configure ]; then
        run ./configure --prefix=${PREFIX}
    fi
    if [ -e Makefile ]; then
        run make -j -s
    fi
}

check() {
    if [ -d "$srcpkgdir" ]; then
        run cd "$srcpkgdir"
    fi
    if [ -e Makefile ]; then
        run make -k check
    fi
}

package() {

    export PREFIX=${prefix:-/usr}
    if [ -e Makefile ]; then
        run make install DESTDIR=$pkgdir PREFIX=${prefix:-/usr}
    else
        tool=$(basename "${sources[0]}")
        tool="${tool%%.*}"
        install -v -D ${pkgname}-${pkgver}*/${pkgname}-${pkgver} $pkgdir/usr/bin/${pkgname}
    fi
}

pkgusage() {
    cat <<- EOF
usage: $0 [-b|--build PKGBUILD] [-d|--debug] [-h|--help] [-g|--generate github/user/pkg]
Build an rpm/deb package from a PKGBUILD definition
EOF
}

fetch() {
    local cache="${HOME}/.cache/pkgbuild/fetch"
    local uri="${1#https://}"
    local dir="$(dirname $uri)"
    local file="$(basename $uri)"
    local json="${cache}/${dir}/${file}.json"
    mkdir -p "$(dirname $json)"
    if ! test -e "$json" || [ $((NOW - $(stat -c %Y $json))) -gt 600 ]; then
        if ! curl -fsSL "$1" | jq -r . > "${json}.tmp"; then
            return 1
        fi
        mv "${json}.tmp" "$json"
    fi
    echo "$json"
}

download() {
    local path="${1#https://}"
    path="${1#http://}"
    local cache="${HOME}/.cache/pkgbuild/sources/${path}"
    if ! test -e "$cache"; then
        info "cache-miss: downloading $1 to $cache"
        curl -fsSL --create-dirs -o "${cache}.tmp" "$1" || die "Failed to download $1 to $cache"
        mv "${cache}.tmp" "$cache"
    else
        info "cache-hit: $1 is in $cache"
    fi
    echo "$cache"
}

pkggenerate() {
    local pkg="${1#https://}"
    url="https://$pkg"
    case "$pkg" in
        github.com/*) ;;
        *) die "Don't know how to generate code for $1. Please use a github.com URL" ;;
    esac
    local repo="${pkg#github.com/}"
    local api="https://api.github.com/repos/$repo" api_json=
    local latest="${api}/releases/latest" latest_json=
    pkgname="${pkgname:-$(basename $pkg)}"

    if api_json=$(fetch "$api") && latest_json=$(fetch $latest); then
        if [ -z "$pkgver" ]; then
            pkgver="$(jq -r .tag_name $latest_json)"
        fi
        pkgver="${pkgver#v}"
        pkgdesc="$(jq -r .description $api_json)"
        pkgrel="${pkgrel:-1}"

        local sources=($(jq -r '.assets[].browser_download_url' $latest_json | grep 'linux' | grep -E '(amd64|x86_64|x64)' | grep -Ev '\.(deb|rpm|pacman)$' | head -1))
        if [ ${#sources[@]} -eq 0 ]; then
            sources=($(jq -r '.assets[].browser_download_url' $latest_json | grep 'amd64' | grep -Ev '(.asc$|SHA)' | head -1))
        fi
        license="$(jq -r .license.name $api_json)"
        local sha256sums=() source=
        for source in "${sources[@]}"; do
            if [ -n "$source" ]; then
                local cache="$(download $source)"
                sha256sums+=($(sha256sum $cache | awk '{print $1}'))
            else
                sha256sums+=('')
            fi
        done
        cat << EOF
pkgname='$pkgname'
pkgver='$pkgver'
pkgdesc='$pkgdesc'
pkgrel=$pkgrel
url='$url'
license='$license'
sources=("${sources[@]//$pkgver/\$\{pkgver\}}")
sha256sums=("${sha256sums[@]}")
prepare() { :; }
build() { :; }
check() { :; }

# This is the default package function. Feel free to modify or
# completely replace it. When you enter in this function you are
# in \$pkgsrc, with your sources[*] extracted (if possible). The
# original files are still present.
package() {
    set -e
    local source0="\$(basename "\${sources[0]}")"
    local tool="\$source0"
    case "\$source0" in
        *.tar.gz) tool="\${source0%%.tar.gz}";;
        *.tar.bz2) tool="\${source0%%.tar.bz2}";;
        *.gz) tool="\${source0%%.gz}";;
        *.bz2) tool="\${source0%%.bz2}";;
        *.zip) tool="\${source0%%.zip}";;
    esac
    if ! [ -e "\$tool" ]; then
        local found_tool=false
        for tool in \$(find -maxdepth 5 -mindepth 1 -type f); do
            if file "\$tool" | grep -q ELF; then
                found_tool=true
                break
            fi
        done
        if ! \$found_tool; then
            die "Expected tool \$tool not found for \$pkgname. Check \$(pwd)"
        fi
    fi
    install -v -D \$tool \$pkgdir/usr/bin/\$pkgname
}
# vim: ft=sh
EOF
    fi
}

pkgmain() {
    CURDIR=$(pwd)
    if [ $# -eq 0 ]; then
        set -- -b PKGBUILD
    fi
    while [ $# -gt 0 ]; do
        local cmd="$1"
        shift
        case "$cmd" in
            -d | --debug) DEBUG=1 ;;
            --no-debug) DEBUG=0 ;;
            --prefix)
                prefix="$1"
                shift
                ;;
            -b | --build)
                PKGBUILD="$1"
                shift
                ;;
            -h | --help) pkgusage ;;
            -g | --generate)
                PKGBUILD="${PKGBUILD:-PKGBUILD}"
                pkggenerate "$1"
                exit $?
                ;;
            -nc | -no-clean)
                CLEAN=false
                ;;
            -gb)
                PKG="$1"
                shift
                PKGBUILD="${PKGBUILD:-PKGBUILD}"
                pkggenerate "$PKG" > ${PKGBUILD}.$$ || die "Failed to generate PKGBUILD"
                mv ${PKGBUILD}.$$ ${PKGBUILD}
                ;;
            -f | --force)
                FORCE=true
                ;;

            *) die "Unknown command: $cmd" ;;
        esac
    done
    PKGBUILD="${PKGBUILD:-PKGBUILD}"
    if ! test -e "$PKGBUILD"; then
        die "PKGBUILD must be specified"
    fi

    . $PKGBUILD

    PKGBUILDdir=$(cd $(dirname $PKGBUILD) && pwd)
    TMPDIR="${TMPDIR:-/tmp}/pkgbuild-$(id -u)/$pkgname"
    pkgdir="${TMPDIR}/rootfs"
    srcdir="${TMPDIR}/srcdir"
    if $CLEAN; then
        rm -rf $TMPDIR
    fi
    mkdir -p $pkgdir $srcdir
    sources+=($source)
    local nsources=${#sources[@]}
    for ii in $(seq 0 $((nsources - 1))); do
        cd $srcdir
        local filen=$(basename ${sources[$ii]}) cache=
        if [ -z "$filen" ]; then
            echo >&2 "WARNING: Empty source decleration in sources[$ii]"
            continue
        fi
        if ! test -e "${PKGBUILDdir}/$filen"; then
            if ! cache="$(download ${sources[$ii]})"; then
                die "Failed to download ${sources[$ii]}"
            fi
            cp "$cache" "${PKGBUILDdir}/$filen"
        fi
        cp "${PKGBUILDdir}/$filen" "$filen"
        sha256=$(sha256sum $filen | awk '{print $1}')
        if [ "${sha256sums[$ii]}" = SKIP ]; then
            echo >&2 "Skipping checksum for ${sources[$ii]}. Please add a valid checksum!"
        elif [ "${sha256sums[$ii]}" = "" ]; then
            echo >&2 "WARNING: Missing checksum for ${sources[$ii]}. It should be $sha256"
        elif [ "${sha256sums[$ii]}" = "0" ]; then
            info "Skipping checksum verification for ${sources[$ii]}"
        elif [ "$sha256" != "${sha256sums[$ii]}" ]; then
            echo >&2 "SHA256($filen) = $sha256"
            info "Removing $cache"
            rm -f "$cache" "$filen"
            die "SHA256 checksum failed for $filen"
        fi
        case "$filen" in
            *.tar.gz) tar zxf "$filen" ;;
            *.tar.bz2) tar xf "$filen" ;;
            *.tar) tar xf "$filen" ;;
            *.zip) unzip -qo "$filen" ;;
            *.gz) gzip -dc "$filen" > "$(basename $filen .gz)" ;;
            *.bz2) bzip2 -dc "$filen" > "$(basename $filen .bz2)" ;;
        esac
    done

    if [ -z "$srcpkgdir" ]; then
        srcpkgdir="${pkgname}-${pkgver}"
    fi
    if [ "${srcpkgdir:0:1}" != / ]; then
        srcpkgdir="${srcdir}/$srcpkgdir"
    fi
    if test -d "$srcpkgdir"; then
        info "Found package subdir (srcpkgdir=$srcpkgdir)"
    else
        info "Not found package subdir (srcpkgdir=$srcpkgdir). Using $srcdir."
        srcpkgdir=$srcdir
    fi

    if type -t prepare > /dev/null; then
        info "Calling prepare ..."
        (
            set -e
            cd $srcpkgdir
            prepare
        ) || die "Failed to prepare"
    fi
    if type -t build > /dev/null; then
        info "Calling build ..."
        (
            set -e
            cd $srcpkgdir
            build
        ) || die "Failed to build"
    fi
    if type -t check > /dev/null; then
        info "Calling check ..."
        (
            set -e
            cd $srcpkgdir
            check
        ) || die "Failed to check"
    fi
    if type -t package > /dev/null; then
        info "Calling package ..."
        (
            cd $srcpkgdir
            package
        ) || die "Failed to package"
    fi
    cd $CURDIR
    FPM_COMMON=(-s dir --name ${pkgname}
        --version ${pkgver#v}
        ${prefix+--prefix $prefix}
        ${pkgrel+--iteration $pkgrel}
        ${license+--license "$license"}
        ${arch+--architecture $arch}
        --description "${pkgdesc}"
        --url "${url}")
    for script in after-install after-remove after-upgrade before-install before-remove before-upgrade; do
        if test -x ${srcdir}/${script}.sh; then
            info "adding --${script} ${srcdir}/${script}.sh"
            FPM_COMMON+=(--${script} ${srcdir}/${script}.sh)
        fi
    done
    if $FORCE; then
        FPM_COMMON+=(-f)
    fi
    FPM_COMMON+=(-C "$pkgdir${prefix}")
    info "building $pkgname rpm ..."
    run fpm -t rpm "${fpmextra[@]}" "${rpmextra[@]}" "${FPM_COMMON[@]}"
    if test -e "${pkgdir}"/etc/sysconfig; then
        mv "${pkgdir}"/etc/sysconfig "${pkgdir}"/etc/default
        for ii in "${pkgdir}"/usr/lib/systemd/system/* "${pkgdir}"/etc/init.d/* "${pkgbuild}"/etc/init/*; do
            sed -i 's@/etc/sysconfig@/etc/default@g' $ii
        done
    fi
    info "building $pkgname deb ..."
    run fpm -t deb "${fpmextra[@]}" "${debextra[@]}" "${FPM_COMMON[@]}"

    if ((DEBUG)); then
        info "Build remenants in $TMPDIR"
    else
        rm -rf $TMPDIR
    fi
}

pkgmain "$@"
