#!/bin/bash

set -e

build_fio() {
    FIOVER=3.18
    FIOURL=https://github.com/axboe/fio/archive/fio-${FIOVER}.tar.gz
    DESTDIR=/tmp/fio$$
    (
        rm -rf fio*
        curl -f -L $FIOURL | tar zxf -
        cd fio*
        ./configure --prefix=/usr
        make -j$(nproc)
        make DESTDIR=$DESTDIR install
    )
    fpm -s dir -t rpm --name fio --version $FIOVER --iteration 10 -f -C $DESTDIR
}

build_ioping() {
    IOVER=1.2
    IOPING=https://github.com/koct9i/ioping/archive/v${IOVER}.tar.gz
    DESTDIR=/tmp/ioping$$
    (
        rm -rf ioping*
        curl -L -f "$IOPING" | tar zxf -
        cd ioping*
        make PREFIX=/usr -j$(nproc)
        make DESTDIR=$DESTDIR install
        mkdir -p $DESTDIR/usr/bin
        mv $DESTDIR/usr/local/* $DESTDIR/usr/
        rm -rf ${DESTDIR:?Dont nuke my computer}/usr/local
    )
    fpm -s dir -t rpm --name ioping --version $IOVER --iteration 10 -f -C $DESTDIR
}

deps() {
    sudo yum install -y make gcc libaio-devel || (apt-get update && apt-get install -y make gcc libaio-dev < /dev/null)
}

get_or_build() {
    if ! command -v "$1" >/dev/null; then
        if ! yum install -y "$1" --enablerepo='xcalar*'; then
            if ! yum install -y $(cd $(dirname ${BASH_SOURCE[0]}) && pwd)/${1}*.rpm; then
                if eval build_"${1}"; then
                    yum install -y "${1}"*.rpm
                fi
            fi
        fi
    fi
}

export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin

if ! command -v fio || ! command -v ioping; then
    if ! yum localinstall -y $(cd $(dirname ${BASH_SOURCE[0]}) && pwd)/{fpm,ioping}*.rpm; then
        deps
        build_fio
        build_ioping
        if ! yum install -y {fpm,ioping}*.rpm; then
            exit 1
        fi
    fi
fi

sudo ioping -c 10 .

sudo fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=test --bs=4k --iodepth=64 --size=4G --readwrite=randrw --rwmixread=75
sudo fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=test --bs=4k --iodepth=64 --size=4G --readwrite=randread
sudo fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=test --bs=4k --iodepth=64 --size=4G --readwrite=randwrite
