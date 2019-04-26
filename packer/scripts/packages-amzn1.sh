#!/bin/bash

install_aws_deps() {
    local tmpdir="$(mktemp -d /tmp/aws.XXXXXX)"
    cd $tmpdir
    curl -L "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o awscli-bundle.zip
    unzip awscli-bundle.zip
    ./awscli-bundle/install -i /opt/aws -b /usr/local/bin/aws
    cd - >/dev/null
    rm -rf "$tmpdir"
}

fix_cloud_init() {
    sed -i '/package-update-upgrade-install/d' /etc/cloud/cloud.cfg.d/00_defaults.cfg
}

OSID=$(osid)

yum install -y "http://repo.xcalar.net/xcalar-release-${OSID}.rpm"
yum erase -y 'ntp*'
yum install -y --enablerepo='xcalar*' --enablerepo=epel \
        ephemeral-disk ec2tools chrony aws-cfn-bootstrap amazon-efs-utils ec2-net-utils ec2-utils \
        deltarpm curl wget tar gzip htop gdb fuse jq nfs-utils iftop iperf3 tmux sysstat python27-pip \
        lvm2 util-linux

service chronyd start
chkconfig chronyd on
install_aws_deps
fix_cloud_init

yum groupinstall -y 'Development tools'
echo 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/xcalar/bin:/opt/aws/bin' > /etc/profile.d/path.sh
. /etc/profile.d/path.sh
pip install -U pip
hash -r
which pip
pip install -U ansible
mkdir -p /etc/ansible
curl -fsSL https://raw.githubusercontent.com/ansible/ansible/devel/examples/ansible.cfg | \
    sed -r 's/^#?host_key_checking.*$/host_key_checking = False/g; s/^#?retry_files_enabled = .*$/retry_files_enabled = False/g' > /etc/ansible/ansible.cfg

for svc in xcalar puppet collectd; do
    chkconfig ${svc} off || true
done
