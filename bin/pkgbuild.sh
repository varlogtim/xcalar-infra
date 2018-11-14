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
PREFIX=/usr

die() {
    echo >&2 "$1"
    exit 1
}

debug() {
    if [ "$DEBUG" = "1" ]; then
        echo >&2 "pkgbuild: debug: $*"
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
    for patch_file in $(ls $srcdir/*.patch $PKGBUILDdir/*.patch 2>/dev/null || true); do
        patch -p1 -i "$patch_file"
    done
    true
}

build() {
    cd "$pkgname-$pkgver"
    ./configure --prefix=${PREFIX}
    make -j -s
}

check() {
    cd "$pkgname-$pkgver"
    make -k check
}

package() {
    cd "$pkgname-$pkgver"
    make install DESTDIR=$pkgdir
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
        if ! curl -fsSL "$1" | jq -r . > "$json"; then
            rm -f "$json"
            return 1
        fi
    fi
    echo "$json"
}

download() {
    local path="${1#https://}"
    local cache="${HOME}/.cache/pkgbuild/sources/${path}"
    if ! test -e "$cache"; then
        info "cache-miss: downloading $1 to $cache"
        curl -fsSL --create-dirs -o "$cache" "$1" || die "Failed to download $1 to $cache"
    else
        info "cache-hit: $1 is in $cache"
    fi
    echo $cache
}

pkggenerate() {
    local pkg="${1#https://}"
    case "$pkg" in
        github.com/*) ;;
        *) die "Don't know how to generate code for $pkg" ;;
    esac
    local repo="${pkg#github.com/}"
    local api="https://api.github.com/repos/$repo"
    local api_json=$(fetch "$api")
    local latest="${api}/releases/latest"
    local latest_json=$(fetch $latest)
    pkgname="${pkgname:-$(basename $pkg)}"
    if [ -z "$pkgver" ]; then
        pkgver="$(jq -r .tag_name $latest_json)"
    fi
    pkgver="${pkgver#v}"
    pkgdesc="$(jq -r .description $api_json)"
    pkgrel="${pkgrel:-1}"

    local sources=($(jq -r '.assets[].browser_download_url' $latest_json | grep 'linux' | grep -E '(amd64|x86_64|x64)' | head -1))
    if [ ${#sources[@]} -eq 0 ]; then
        sources=($(jq -r '.assets[].browser_download_url' $latest_json | grep 'amd64' | grep -Ev '(.asc$|SHA)' | head -1))
    fi
    url="https://$pkg"
    license="$(jq -r .license.spdx_id $api_json)"
    local sha256sums=() source=
    for source in "${sources[@]}"; do
        local cache="$(download $source)"
        sha256sums+=($(sha256sum $cache | awk '{print $1}'))
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
package() {
    set -e
    local source0=\$(basename \${sources[0]})
    local tool="\${source0%%.*}"
    install -v -D \$tool \$pkgdir/usr/bin/\$pkgname
}

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
        for tool in \$(find -maxdepth 1 -mindepth 1 -type f); do
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
}

pkgmain() {
    CURDIR=$(pwd)
    while [ $# -gt 0 ]; do
        local cmd="$1"
        shift
        case "$cmd" in
            -d | --debug) DEBUG=1 ;;
            --no-debug) DEBUG=0 ;;
            --prefix)
                PREFIX="$1"
                shift
                ;;
            -b | --build)
                PKGBUILD="$1"
                shift
                ;;
            -h | --help) pkgusage ;;
            -g | --generate)
                PKGBUILD="${PKGBUILD:-$(basename $CURDIR).pkgbuild}"
                pkggenerate "$1"
                exit $?
                ;;
            -gb)
                PKG="$1"
                shift
                PKGBUILD="${PKGBUILD:-$(basename $CURDIR).pkgbuild}"
                pkggenerate "$PKG" > $PKGBUILD || die "Failed to generate PKGBUILD"
                ;;
            -f | --force)
                FORCE=-f;;

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
    rm -rf $TMPDIR
    mkdir -p $pkgdir $srcdir
    cp * $srcdir/
    cd $srcdir
    local nsources=${#sources[@]}
    for ii in $(seq 0 $((nsources - 1))); do
        local filen=$(basename ${sources[$ii]}) cache=
        if ! cache="$(download ${sources[$ii]})"; then
            die "Failed to download ${sources[$ii]}"
        fi
        cp "$cache" "$filen"
        sha256=$(sha256sum $filen | awk '{print $1}')
        if [ "${sha256sums[$ii]}" = "" ]; then
            echo >&2 "WARNING: Missing checksum for ${sources[$ii]}. It should be $sha256"
        elif [ "$sha256" != "${sha256sums[$ii]}" ]; then
            echo >&2 "SHA256($filen) = $sha256"
            info "Removing $cache"
            rm -f "$cache" "$filen"
            die "SHA256 checksum failed for $filen"
        fi
        case "$filen" in
            *.tar.gz) tar zxf "$filen" ;;
            *.tar.bz2) tar Jxf "$filen" ;;
            *.tar) tar xf "$filen" ;;
            *.zip) unzip -q -o -k "$filen" ;;
            *.gz) gzip -dc "$filen" > "$(basename $filen .gz)" ;;
            *.bz2) bzip2 -dc "$filen" > "$(basename $filen .bz2)" ;;
        esac
    done

    if type -t prepare > /dev/null; then
        cd $srcdir
        prepare || die "Failed to prepare"
    fi
    if type -t build > /dev/null; then
        cd $srcdir
        build || die "Failed to build"
    fi
    if type -t check > /dev/null; then
        cd $srcdir
        check || die "Failed to check"
    fi
    if type -t package > /dev/null; then
        cd $srcdir
        package || die "Failed to package"
    fi
    cd $CURDIR
    FPM_COMMON=(-s dir --name ${pkgname} \
        --version ${pkgver#v} \
        ${pkgrel+--iteration $pkgrel} \
        ${license+--license "$license"} \
        ${arch+--architecture $arch} \
        --description "${pkgdesc}" \
        --url "${url}")
    for script in after-install after-remove after-upgrade before-install before-remove before-upgrade; do
        if test -x ${script}.sh; then
            FPM_COMMON+=(--${script} ${script}.sh)
        fi
    done
    FPM_COMMON+=(${FORCE} -C "$pkgdir")
    info "building $pkgname rpm ..."
    debug fpm -t rpm "${FPM_COMMON[@]}"
    info "building $pkgname deb ..."
    debug fpm -t deb --deb-no-default-config-files "${FPM_COMMON[@]}"

    rm -rf $TMPDIR
}

pkgmain "$@"
