#!/bin/bash

set -x
if [ -e  /var/cache/yum ]; then
    yum clean all
    rm -rf /var/cache/yum/*
    yum -y upgrade --disablerepo='xcalar*'
    yum clean all
    rm -rf /var/cache/yum/*
fi

date > /etc/packer_build_time

truncate -s 0 /var/log/messages /var/log/cloud-init*

rm -f /var/log/startupscript.log
rm -f /etc/hostname

#if test -e /usr/sbin/waagent; then
#	echo >&2 "Running Azure deprovisioner ..."
#	/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync
#fi
#
exit 0

set +e

if [ "$REMOVE_XCALAR" = 1 ]; then
    if test -e /etc/system-release; then
        #yum remove -y xcalar
        rm -f /etc/httpd/conf.d/X*.conf /etc/httpd/conf.d/*.bak

        RELEASE_RPM=$(rpm -qf /etc/redhat-release)
        RELEASE=$(rpm -q --qf '%{VERSION}' ${RELEASE_RPM})
        case "$RELEASE" in
            6*)
                ;;
            7*)
                ;;
        esac
    else
        service xcalar stop-supervisor
        apt-get purge -y xcalar
        rm -f /etc/apache2/conf.d/X*.conf /etc/apache2/conf.d/*.bak
        /etc/apache2/*-enabled/X*.conf
        /etc/apache2/*-available/X*.conf
        umount /mnt/xcalar || true
        sed -i.bak '\@/mnt/xcalar@d' /etc/fstab || true
    fi

    rm -f /etc/default/xcalar /etc/xcalar/default.cfg

    rm -rf /etc/xcalar/
fi

if [ "$DISABLE_HTTP" = 1 ]; then
    if [ -n "$VERSTRING" ]; then
        case "$VERSTRING" in
            rhel6|el6)
                chkconfig httpd off
                ;;
            rhel7|el7)
                systemctl disable httpd
                ;;
            ub14)
                update-rc.d apache2 disable
                ;;
            ub16)
                systemctl disable apache2
                ;;
        esac
    fi
fi

exit 0

#mkdir -p /netstore /freenas
#echo 'netstore.int.xcalar.com:/public/netstore /netstore   nfs    defaults    0   0' | tee -a /etc/fstab
#echo 'freenas.int.xcalar.com:/mnt/netstore/netstore           /freenas    nfs    defaults    0   0' | tee -a /etc/fstab
#if test -e /run/shm; then
#    echo 'none    /run/shm    tmpfs   defaults,size=21G   0   0' | tee -a /etc/fstab
#else
#    echo 'none    /dev/shm    tmpfs   defaults,size=21G   0   0' | tee -a /etc/fstab
#fi
