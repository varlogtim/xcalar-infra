#!/bin/bash

ROOTFS="${ROOTFS:-}"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/puppetlabs/bin:/root/bin

die() {
    echo >&2 "ERROR: $1"
    exit 1
}

say() {
    echo >&2 "$1"
}

if [ $(id -u) != 0 ]; then
    die "This script needs to run as root!"
fi

if ! test -e ${ROOTFS}/etc/system-release; then
    die "This script is only for EL Operating Systems!"
fi

## Set DEPROVISION_NETWORK=0 or 1 to clean up network settings
if [ -z "${DEPROVISION_NETWORK:-}" ]; then
    if [ -n "$CLOUD" ] || [ -n "$FACTER_cloud" ]; then
        DEPROVISION_NETWORK=0
    else
        DEPROVISION_NETWORK=1
    fi
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
    8) INIT=systemd ;;
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
        test -e ${ROOTFS}/etc/init.d/$1
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
            start | stop | restart | status | stop-supervisor) ${ROOTFS}/sbin/service $svc $cmd ;;
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
    rm -v -rf ${ROOTFS}/etc/puppetlabs/puppet/ssl ${ROOTFS}/etc/puppetlabs/code
    sed -i '/certname/d' ${ROOTFS}/etc/puppetlabs/puppet/puppet.conf
fi

if have_package collectd; then
    svc_cmd stop collectd
    svc_cmd disable collectd
    rm -fv ${ROOTFS}/var/lib/collectd/*
fi

if have_package node_exporter; then
    svc_cmd stop node_exporter
    svc_cmd disable node_exporter
    rm -fv ${ROOTFS}/var/lib/node_exporter/*
fi

if have_package cloud-init; then
    svc_cmd enable cloud-config
    svc_cmd enable cloud-init
    svc_cmd enable cloud-init-local
    svc_cmd enable cloud-final
    rm -rfv  ${ROOTFS}/var/lib/cloud/instance/*
    rm -fv  ${ROOTFS}/var/lib/cloud/instance
    truncate -s 0 ${ROOTFS}/var/log/cloud*.log ${ROOTFS}/var/log/user-data*.log
    if [ -z "$CLOUD" ] || [ "$CLOUD" = none ]; then
        cat > ${ROOTFS}/etc/cloud/cloud.cfg.d/90-networking-disabled.cfg <<EOF
network:
  config: disabled
EOF
        sed -i '/package-update-upgrade-install/d; /datasource_list/d; s/disable_root:.*$/disable_root: 0/g; s/ssh_pwauth.*$/ssh_pwauth: 1/g' ${ROOTFS}/etc/cloud/cloud.cfg
        sed -i '/datasource_list:/d' ${ROOTFS}/etc/cloud/cloud.cfg
        echo 'datasource_list: [ ConfigDrive, NoCloud, None ]' >> ${ROOTFS}/etc/cloud/cloud.cfg
    fi
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
    consul leave || true
    svc_cmd stop consul
    svc_cmd disable consul
    rm -rf ${ROOTFS}/var/lib/consul/*
    rm -rf ${ROOTFS}/etc/consul.d/*
fi

if have_program caddy; then
    svc_cmd stop caddy
    svc_cmd disable caddy
fi

if have_program nomad; then
    svc_cmd stop nomad
    svc_cmd disable nomad
    rm -rf ${ROOTFS}/var/lib/nomad/*
    rm -rfv ${ROOTFS}/var/lib/nomad/*
fi

if ((DEPROVISION_NETWORK)); then
    cat >/etc/sysconfig/network <<-EOF
	NETWORKING=yes
	ONBOOT=yes
	BOOTPROTO=dhcp
	EOF

    rm -v -f ${ROOTFS}/etc/sysconfig/network-scripts/ifcfg-e*

    cat >/etc/sysconfig/network-scripts/ifcfg-eth0 <<-EOF
	DEVICE=eth0
	NAME=eth0
	ONBOOT=yes
	IPV6INIT=yes
	BOOTPROTO=dhcp
	EOF

    echo 'RUN_FIRSTBOOT=NO' >${ROOTFS}/etc/sysconfig/firstboot

    rm -f ${ROOTFS}/etc/udev/rules.d/70-persistent-net.rules
    ln -sfn /dev/null ${ROOTFS}/etc/udev/rules.d/80-net-name-slot.rules

    if [ $ELVERSION = 7 ]; then
        sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=0/g' ${ROOTFS}/etc/default/grub
        if ! grep -q 'net.ifnames=0' ${ROOTFS}/etc/default/grub; then
            sed -i 's/rhgb quiet/net.ifnames=0 biosdevname=0/g' ${ROOTFS}/etc/default/grub
        fi
        sed -i 's/rhgb quiet//g' ${ROOTFS}/etc/default/grub

        grub2-mkconfig -o ${ROOTFS}/boot/grub2/grub.cfg
        if [ -d ${ROOTFS}/boot/efi/EFI/redhat ]; then
            grub2-mkconfig -o ${ROOTFS}/boot/efi/EFI/redhat/grub.cfg
        fi
        dracut --no-hostonly --force
    fi
fi

# Remove all registration info
if  [[ $RELEASE =~ ^redhat- ]]; then
    subscription-manager unsubscribe --all || true
    subscription-manager unregister || true
    subscription-manager clean || true
fi

truncate -s 0 ${ROOTFS}/etc/machine-id
rm -fv ${ROOTFS}/etc/sysconfig/rhn/systemid
rm -fv ${ROOTFS}/root/.bash_history ${ROOTFS}/home/*/.bash_history
history -c

yum clean all --enablerepo='*'
rm -rf ${ROOTFS}/var/cache/yum/*

cat >/etc/hosts <<EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF

if ((DEPROVISION_NETWORK)); then
    rm -f ${ROOTFS}/etc/hostname
    if command -v hostnamectl >/dev/null; then
        hostnamectl set-hostname 'localhost.localdomain'
    else
        hostname 'localhost.localdomain'
    fi
fi

exit 0
