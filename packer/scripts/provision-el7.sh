#!/bin/bash
set -ex

setenforce 0
sed --follow-symlinks -i 's/^SELINUX=.*$/SELINUX=disabled/g' /etc/sysconfig/selinux

curl -sSL http://repo.xcalar.net/builds/prod/xcalar-1.0.2.16-521.589354b9-installer > /tmp/xcalar-install
bash /tmp/xcalar-install --noStart
rm -f /tmp/xcalar-install
cat /etc/sysctl.d/90-xcsysctl.conf >> /etc/sysctl.conf
cat /etc/security/limits.d/90-xclimits.conf >> /etc/security/limits.conf
yum remove -y xcalar
yum install -y collectd htop gdb
systemctl disable httpd.service
rm -rf /opt/xcalar /var/opt/xcalar /etc/xcalar/
