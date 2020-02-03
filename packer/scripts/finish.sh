#!/bin/bash

set -x
if [ -e  /var/cache/yum ]; then
    yum clean all --enablerepo='*'
    rm -rf /var/cache/yum/*
fi

sed -i '/^proxy/d' /etc/yum.conf


truncate -s 0 /var/log/secure /var/log/messages /var/log/dmesg /var/log/audit/audit.log || true

rm -fv /var/log/startupscript.log /var/log/dmesg.old /var/log/cfn-* /var/log/cloud-init* /var/log/user-data*
rm -fv /etc/hostname /root/.bash_history /home/*/.bash_history
rm -rf $HOME/.cache /root/.cache
if [[ "$PACKER_BUILDER_TYPE" =~ amazon ]] || [[ "$PACKER_BUILDER_TYPE" =~ azure ]]; then
    echo >&2 "Detected PACKER_BUILDER_TYPE=$PACKER_BUILDER_TYPE, deleting authorized_keys"
    rm -fv /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys
fi

rm -rfv /var/lib/cloud/instances/*

: >/var/log/lastlog
: >/var/log/wtmp
: >/var/log/btmp

date -u +%FT%T%z > /etc/packer_build_time

history -c
export HISTSIZE=0
export HISTFILESIZE=0

rm -rfv /tmp/*

if test -e /usr/sbin/waagent; then
	echo >&2 "Running Azure deprovisioner ..."
	/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync
fi
sync
exit 0
