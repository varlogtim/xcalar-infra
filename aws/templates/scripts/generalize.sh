#!/bin/bash

ROOTFS="${ROOTFS:-}"
echo "WARNING: This script will nuke and generalize this machine!!!"
echo "PRESS Ctrl-C to exit"
(set -x; sleep 10)
if ! grep -q '7\.[2-9]' ${ROOTFS}/etc/redhat-release; then
    echo "This script is only for EL7 VMs. Check /etc/redhat-release" >&2
    exit 1
fi


exit 0

systemctl enable cloud-config
systemctl enable cloud-init
systemctl enable cloud-init-local
systemctl enable cloud-final
systemctl enable --now chronyd
systemctl disable --now puppet.service
rm -rf ${ROOTFS}/etc/puppetlabs/puppet/ssl
rm -f ${ROOTFS}/etc/facter/facts.d/*
sed -i '/^certname/d; /^server/d'  ${ROOTFS}/etc/puppetlabs/puppet/puppet.conf
yum clean all --enablerepo='*'
rm -rf ${ROOTFS}/var/cache/yum/*
rm -rf ${ROOTFS}/etc/ssh/ssh_host_*

rm -rf /etc/hostname
hostnamectl set-hostname 'localhost'
cat > ${ROOTFS}/etc/hosts <<EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
EOF
cat > ${ROOTFS}/etc/default/grub <<'END'
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="crashkernel=auto console=ttyS0,115200n8 console=tty0 net.ifnames=0"
GRUB_DISABLE_RECOVERY="true"
END
echo 'RUN_FIRSTBOOT=NO' > ${ROOTFS}/etc/sysconfig/firstboot

grub2-mkconfig -o ${ROOTFS}/boot/grub2/grub.cfg
dracut --no-hostonly --force

rm -f ${ROOTFS}/etc/udev/rules.d/*-persistent-*.rules
sed -i '/^HWADDR=/d' ${ROOTFS}/etc/sysconfig/network-scripts/ifcfg-*
sed -i '/^UUID=/d' ${ROOTFS}/etc/sysconfig/network-scripts/ifcfg-*
cat > ${ROOTFS}/etc/sysconfig/network <<EOF
NETWORKING=yes
NOZEROCONF=yes
NETWORKING_IPV6=yes
EOF
cat > ${ROOTFS}/etc/sysconfig/network-scripts/ifcfg-eth0 <<EOF
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=Ethernet
USERCTL=yes
PEERDNS=yes
IPV6INIT=yes
PERSISTENT_DHCLIENT=yes
NM_CONTROLLED=no
EOF
: > ${ROOTFS}/etc/machine-id
rm -f ${ROOTFS}/etc/sysconfig/rhn/systemid
rm -f ${ROOTFS}/root/.bash_history
rm -f ${ROOTFS}/root/${HISTFILE} ${ROOTFS}/home/*/.bash_history

HISTFILESIZE=0
HISTSIZE=0
HISTFILE=/dev/null

history -c

touch /.unconfigured

shutdown -h now
