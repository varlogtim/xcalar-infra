#!/bin/bash

ROOTFS="${ROOTFS:-}"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/puppetlabs/bin:/root/bin

die() {
    echo >&2 "ERROR: $1"
    exit ${2:-1}
}

say() {
    echo >&2 "$1"
}

if [ $(id -u) != 0 ]; then
    die "This script needs to run as root!"
fi

if ! test -e /etc/system-release; then
    die "This script is only for EL Operating Systems!" 2
fi

RELEASE=$(rpm -qf /etc/system-release --qf '%{NAME}')
VERSION=$(rpm -qf /etc/system-release --qf '%{VERSION}')
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
    *) die "Shouldn't have gotten here: ${RELEASE} ${VERSION} ${ELVERSION}" ;;
esac

if [ "$INIT" = systemd ]; then
    svc_exists() {
        systemctl cat $1 >/dev/null 2>&1
    }

    svc_cmd() {
        if svc_exists $2; then
            systemctl $1 $2
            return $?
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
            start | stop | restart | status | stop-supervisor) /sbin/service $svc $cmd ;;
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
    svc_cmd stop puppet
    if [[ $NODISABLE =~ puppet ]]; then
        echo >&2 "Keeping puppet due to NODISABLE=\"$NODISABLE\""
    else
        svc_cmd disable puppet
    fi
    rm -v -rf /etc/puppetlabs/puppet/ssl
    sed -i '/^certname/d' /etc/puppetlabs/puppet/puppet.conf
fi

if have_package collectd; then
    svc_cmd stop collectd
    svc_cmd disable collectd
    rm -fv /etc/collectd.d/*
fi

if have_package cloud-init; then
    svc_cmd enable cloud-config
    svc_cmd enable cloud-init
    svc_cmd enable cloud-init-local
    svc_cmd enable cloud-final
    rm -f /var/log/cloud*.log
fi

if have_package chrony; then
    svc_cmd enable chronyd
fi

if have_package cronie; then
    svc_cmd enable crond
    svc_cmd start crond
fi

if have_package at; then
    svc_cmd enable atd
    svc_cmd start atd
fi

if have_program consul; then
    consul leave
    svc_cmd stop consul
    svc_cmd disable consul
    rm -rf /var/lib/consul/*
fi

if have_program caddy; then
    svc_cmd stop caddy
    svc_cmd disable caddy
fi

if have_program nomad; then
    svc_cmd stop nomad
    svc_cmd disable nomad
    rm -rf /var/lib/nomad/*
fi

cat >/etc/sysconfig/network <<EOF
NETWORKING=yes
NOZEROCONF=yes
NETWORKING_IPV6=yes
ONBOOT=yes
EOF

sed -r -i '/(HWADDR|UUID|IPADDR|NETWORK|NETMASK|USERCTL)/d' /etc/sysconfig/network-scripts/ifcfg-e*
rm -v -f /etc/sysconfig/network-scripts/ifcfg-e*

cat >/etc/sysconfig/network-scripts/ifcfg-eth0 <<EOF
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
NM_CONTROLLED="no"
EOF

echo 'RUN_FIRSTBOOT=NO' >/etc/sysconfig/firstboot

rm -f /etc/udev/rules.d/70-persistent-net.rules
ln -sfn /dev/null /etc/udev/rules.d/80-net-name-slot.rules

if [ $ELVERSION = 7 ]; then
    sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=0/g' /etc/default/grub
    if ! grep -q 'net.ifnames=0' /etc/default/grub; then
        sed -i 's/rhgb quiet/net.ifnames=0 biosdevname=0/g' /etc/default/grub
    fi
    sed -i 's/rhgb quiet//g' /etc/default/grub

    grub2-mkconfig -o /boot/grub2/grub.cfg
    if [ -d /boot/efi/EFI/redhat ]; then
        grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
    fi
    dracut --no-hostonly --force
fi


# Remove all registration info
if  [[ $RELEASE =~ ^redhat- ]]; then
    subscription-manager unsubscribe --all || true
    subscription-manager unregister || true
    subscription-manager clean || true
fi

: >/etc/machine-id
rm -fv /etc/sysconfig/rhn/systemid
rm -fv /root/.bash_history /home/*/.bash_history

yum clean all --enablerepo='*'
rm -rf /var/cache/yum/*

cat >/etc/hosts <<EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF
rm -f /etc/hostname
if command -v hostnamectl >/dev/null; then
    hostnamectl set-hostname 'localhost.localdomain'
else
    hostname 'localhost.localdomain'
fi
sed -i '/HOSTNAME=/d' /etc/sysconfig/network

export HISTFILESIZE=0
export HISTSIZE=0

waagent=$(command -v waagent)
if [ -n "$waagent" ]; then
    svc_cmd atd start
    cd /
    echo "$waagent -force -deprovision+user > /tmp/depro.out 2> /tmp/depro.err && poweroff" | at now + 1 minute
    if [ $? -eq 0 ]; then
        echo >&2 "Deprovisioning in 1min. Please logout"
        exit 0
    fi
    $waagent -force -deprovision+user
fi
exit 0
