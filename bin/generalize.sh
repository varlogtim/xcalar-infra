#!/bin/bash

ROOTFS="${ROOTFS:-}"

export PATH=/opt/puppetlabs/bin:/usr/local/sbin:/usr/sbin:/usr/local/bin:/usr/bin:/sbin:/bin

die() {
    echo >&2 "ERROR: $1"
    exit ${2:-1}
}

say() {
    echo >&2 "$1"
}

if [ `id -u` != 0 ]; then
    die "This script needs to run as root!"
fi

if ! test -e ${ROOTFS}/etc/system-release; then
    die "This script is only for EL Operating Systems!" 2
fi

RELEASE=$(rpm -qf ${ROOTFS}/etc/system-release --qf '%{NAME}')
VERSION=$(rpm -qf ${ROOTFS}/etc/system-release --qf '%{VERSION}')
case "$RELEASE" in
    centos* | oracle* | redhat*)
        ELVERSION="${VERSION:0:1}"
        OSID="el${ELVERSION}"
        ;;
    system*)
        if [ "$VERSION" = 2 ]; then
            ELVERSION=7
            OSID="amzn2"
        else
            ELVERSION=6
            OSID="amzn1"
        fi
        ;;
    *) die "Unknown OS: ${RELEASE} ${VERSION}" ;;
esac

case "$ELVERSION" in
    6) INIT=init ;;
    7) INIT=systemd ;;
    *) die "Shouldn't have gotten here: ${RELEASE} ${VERSION} ${ELRELEASE} ${ELVERSION}" ;;
esac

if [ "$INIT" = systemd ]; then
    svc_exists() {
        systemctl cat $1 >/dev/null 2>&1
    }

    svc_cmd() {
        if svc_exists $2; then
            systemctl $1 $2
        else
            say "svc_cmd: No such unit: $2 for $1"
        fi
    }
else
    svc_exists() {
        test -e /etc/init.d/$1
    }

    svc_cmd() {
        local cmd="$1" svc="$2"
        shift 2
        if ! svc_exists $svc; then
            say "svc_cmd: No such service: $svc $cmd"
            return 0
        fi
        say "svc_cmd $cmd $svc"
        case "$cmd" in
            disable) chkconfig $svc off ;;
            enable) chkconfig $svc on ;;
            start | stop | restart | status | stop-supervisor) /usr/sbin/service $svc $cmd ;;
            *) die "svc_cmd: Unknown command: $svc $cmd" ;;
        esac
    }
fi

have_package() {
    rpm -q "$1" >/dev/null 2>&1
}

have_program() {
    command -v "$1" >/dev/null 2>&1
}

echo >&2 "WARNING: This script will nuke and generalize this machine!!!"
echo >&2 "WARNING: The system will be shutdown after!!!"
echo "PRESS Ctrl-C to exit"
(
    set -x
    sleep 10
)

if have_package puppet-agent; then
    svc_cmd stop puppet-agent
    svc_cmd disable puppet-agent
    rm -rf ${ROOTFS}/etc/puppetlabs/puppet/ssl
    rm -f ${ROOTFS}/etc/facter/facts.d/*
    sed -i '/^certname/d; /^server/d; /^environment/d' ${ROOTFS}/etc/puppetlabs/puppet/puppet.conf
fi

if have_package collectd; then
    svc_cmd stop collectd
    svc_cmd disable collectd
    rm -fv ${ROOTFS}/etc/collectd.d/*
fi

if have_package cloud-init; then
    svc_cmd enable cloud-config
    svc_cmd enable cloud-init
    svc_cmd enable cloud-init-local
    svc_cmd enable cloud-final
    rm -f ${ROOTFS}/var/log/cloud*.log
fi

if have_package chronyd; then
    svc_cmd enable chronyd
fi

if have_program consul; then
    svc_cmd stop consul
    svc_cmd disable consul
    rm -rf ${ROOTFS}/var/lib/consul/*
fi

if have_program caddy; then
    svc stop caddy
    svc disable caddy
fi

if have_program nomad; then
    svc_cmd stop nomad
    svc_cmd disable nomad
    rm -rf i${ROOTFS}/var/lib/nomad/*
fi

if [ $ELVERSION = 7 ]; then
    IFACE=$(ip route list match 0/0 | awk '{print $5}')
    if [ "$IFACE" != eth0 ]; then
        sed -i 's/rhgb quiet/net.ifnames=0 biosdevname=0/' ${ROOTFS}/etc/default/grub
        grub2-mkconfig -o ${ROOTFS}/boot/grub2/grub.cfg
        if [ -d ${ROOTFS}/boot/efi/EFI/redhat ]; then
            grub2-mkconfig -o ${ROOTFS}/boot/efi/EFI/redhat/grub.cfg
        fi
        dracut --no-hostonly --force
    fi
fi

rm -f ${ROOTFS}/etc/sysconfig/network-scripts/ifcfg-en*
cat >${ROOTFS}/etc/sysconfig/network-scripts/ifcfg-eth0 <<EOF
DEVICE="eth0"
NAME="eth0"
ONBOOT="yes"
NETBOOT="yes"
IPV6INIT="yes"
BOOTPROTO="dhcp"
TYPE="Ethernet"
PROXY_METHOD="none"
BROWSER_ONLY="no"
DEFROUTE="yes"
IPV4_FAILURE_FATAL="no"
IPV6_AUTOCONF="yes"
IPV6_DEFROUTE="yes"
IPV6_FAILURE_FATAL="no"
EOF

echo 'RUN_FIRSTBOOT=NO' >${ROOTFS}/etc/sysconfig/firstboot

rm -f ${ROOTFS}/etc/udev/rules.d/*-persistent-net.rules
cat >${ROOTFS}/etc/sysconfig/network <<EOF
NETWORKING=yes
NOZEROCONF=yes
NETWORKING_IPV6=yes
EOF

: >${ROOTFS}/etc/machine-id
rm -fv ${ROOTFS}/etc/sysconfig/rhn/systemid
rm -fv ${ROOTFS}/root/.bash_history ${ROOTFS}/home/*/.bash_history

yum clean all --enablerepo='*'
rm -rf ${ROOTFS}/var/cache/yum/*
rm -rfv ${ROOTFS}/etc/ssh/ssh_host_*

cat >${ROOTFS}/etc/hosts <<EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF
rm -f /etc/hostname
if [ $ELVERSION = 6 ]; then
    hostname 'localhost.localdomain'
    sed -i '/HOSTNAME=/d' ${ROOTFS}/etc/sysconfig/network
    echo HOSTNAME=localhost.localdomain >>${ROOTFS}/etc/sysconfig/network
elif [ $ELVERSION = 7 ]; then
    hostnamectl set-hostname 'localhost.localdomain'
fi

HISTFILESIZE=0
HISTSIZE=0

touch /.unconfigured
shutdown -h now
