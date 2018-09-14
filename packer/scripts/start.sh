#!/bin/bash

set -ex

env

get_meta_data () {
    local http_code=
    http_code="$(curl -H "Metadata-Flavor:Google" -sSL "http://169.254.169.254/$1" -w '%{http_code}\n' -o /dev/null)"
    if [ "$http_code" = 200 ]; then
        curl -H "Metadata-Flavor:Google" -sSL "http://169.254.169.254/$1" && return 0
        return 2
    fi
    return 1
}

get_cloud_cfg () {
    # Check for metadata service
    CLOUD= INSTANCE_ID= INSTANCE_TYPE=
    if INSTANCE_ID="$(get_meta_data latest/meta-data/instance-id)"; then
        CLOUD=aws
        INSTANCE_TYPE="$(get_meta_data latest/meta-data/instance-type)"
    elif INSTANCE_ID="$(get_meta_data computeMetadata/v1/instance/id)"; then
        CLOUD=gce
        INSTANCE_TYPE="$(get_meta_data computeMetadata/v1/instance/machine-type)"
        INSTANCE_TYPE="${INSTANCE_TYPE##*/}"
    else
        CLOUD= INSTANCE_ID= INSTANCE_TYPE=
    fi
    echo CLOUD=$CLOUD
    echo INSTANCE_ID=$INSTANCE_ID
    echo INSTANCE_TYPE=$INSTANCE_TYPE
}

keep_trying () {
    local -i try=0
    for try in {1..20}; do
        if eval "$@"; then
            return 0
        fi
        echo "Failed to $* .. sleeping"
        sleep 10
        try=$(($try + 1))
        if [ $try -gt 20 ]; then
            return 1
        fi
    done
    return 0
}


if test -e /etc/system-release; then
    setenforce Permissive || true
    if test -f /etc/sysconfig/selinux; then
        sed -i --follow-symlinks 's/^SELINUX=.*$/SELINUX=permissive/g' /etc/sysconfig/selinux
    fi
    yum clean all
    rm -rf /var/cache/yum/*
    keep_trying yum update -y
    EXTRA="bonnie++ xfsprogs bwm-ng cifs-utils"
    yum install -y -q sudo lvm2 mdadm btrfs-progs yum-utils fuse || true
else
    export DEBIAN_FRONTEND=noninteractive
    keep_trying apt-get update -q
    apt-get -yqq install linux-generic-lts-xenial curl lvm2 xfsprogs bonnie++ bwm-ng mdadm btrfs-tools
    apt-get -yqq dist-upgrade
    apt-get -yqq autoremove
fi

eval `get_cloud_cfg`
if [ "$CLOUD" = gce ]; then
    if [[ -e /etc/redhat-release ]]; then
        yum localinstall -y http://repo.xcalar.net/deps/gce-scripts-1.3.2-1.noarch.rpm
        yum localinstall -y http://repo.xcalar.net/deps/gcsfuse-0.20.1-1.x86_64.rpm
    fi
elif [ "$CLOUD" = aws ]; then
    curl -sSL http://repo.xcalar.net/deps/ec2-tags-v3 > /usr/local/bin/ec2-tags-v3
    chmod +x /usr/local/bin/ec2-tags-v3
    ln -sfn ec2-tags-v3 /usr/local/bin/ec2-tags
fi


getent group sudo || groupadd -f -r sudo
echo '%sudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-sudo && chmod 0440 /etc/sudoers.d/99-sudo
getent group docker || groupadd -f -r --non-unique -g 999 docker

curl -sSL http://repo.xcalar.net/scripts/osid > /usr/bin/osid
chmod +x /usr/bin/osid

if test -n "$BUILD_CONTEXT"; then
    curl -sSL "$BUILD_CONTEXT" | tar zxvf -
fi
