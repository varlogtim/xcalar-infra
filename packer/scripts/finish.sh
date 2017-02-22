#!/bin/bash

set -x
date > /etc/packer_build_time

rm -f /var/log/startupscript.log
rm -f /etc/hostname
#mkdir -p /netstore /freenas
#echo 'netstore.int.xcalar.com:/public/netstore /netstore   nfs    defaults    0   0' | tee -a /etc/fstab
#echo 'freenas.int.xcalar.com:/mnt/netstore/netstore           /freenas    nfs    defaults    0   0' | tee -a /etc/fstab
#if test -e /run/shm; then
#    echo 'none    /run/shm    tmpfs   defaults,size=21G   0   0' | tee -a /etc/fstab
#else
#    echo 'none    /dev/shm    tmpfs   defaults,size=21G   0   0' | tee -a /etc/fstab
#fi
