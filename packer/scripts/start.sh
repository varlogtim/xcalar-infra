#!/bin/bash

set -ex

env

get_meta_data() {
    local http_code=
    http_code="$(curl -H "Metadata-Flavor:Google" -f -sL "http://169.254.169.254/$1" -w '%{http_code}\n' -o /dev/null)"
    if [ "$http_code" = 200 ]; then
        curl -H "Metadata-Flavor:Google" -f -sL "http://169.254.169.254/$1" && return 0
        return 2
    elif curl -H 'Metadata:True' -f -sL "http://169.254.169.254/metadata/instance/$1?api-version=2018-02-01&format=text"; then
        return 0
    fi
    return 1
}

get_cloud_cfg() {
    # Check for metadata service
    CLOUD= INSTANCE_ID= INSTANCE_TYPE=
    if INSTANCE_ID="$(get_meta_data latest/meta-data/instance-id)"; then
        CLOUD=aws
        INSTANCE_TYPE="$(get_meta_data latest/meta-data/instance-type)"
    elif INSTANCE_ID="$(get_meta_data computeMetadata/v1/instance/id)"; then
        CLOUD=gce
        INSTANCE_TYPE="$(get_meta_data computeMetadata/v1/instance/machine-type)"
        INSTANCE_TYPE="${INSTANCE_TYPE##*/}"
    elif INSTANCE_ID="$(get_meta_data compute/vmId)"; then
        CLOUD=azure
        INSTANCE_TYPE="$(get_meta_data compute/vmSize)"
    else
        CLOUD= INSTANCE_ID= INSTANCE_TYPE=
    fi
    echo CLOUD=$CLOUD
    echo INSTANCE_ID=$INSTANCE_ID
    echo INSTANCE_TYPE=$INSTANCE_TYPE
}

keep_trying() {
    local -i try=0
    for try in {1..20}; do
        if eval "$@"; then
            return 0
        fi
        echo "Failed to $* .. sleeping"
        sleep 10
        try=$((try + 1))
        if [ $try -gt 20 ]; then
            return 1
        fi
    done
    return 0
}

curl -fsSL http://repo.xcalar.net/scripts/osid -o /usr/bin/osid
chmod +x /usr/bin/osid
OSID=$(osid)

if test -e /etc/system-release; then
    if test -f /etc/selinux/config; then
        setenforce 0 || true
        sed -i 's/^SELINUX=.*$/SELINUX=disabled/g' /etc/selinux/config
    fi
    yum clean all --enablerepo='*'
    rm -rf /var/cache/yum/*
    yum remove -y java java-1.7.0-openjdk || true
    keep_trying yum update -y
    keep_trying yum install -y http://repo.xcalar.net/xcalar-release-${OSID}.rpm
    yum install -y -q --enablerepo='xcalar-*' nfs-utils xfsprogs sudo lvm2 mdadm btrfs-progs yum-utils fuse || true
else
    export DEBIAN_FRONTEND=noninteractive
    keep_trying apt-get update -q
    apt-get -yqq install linux-generic-lts-xenial curl lvm2 xfsprogs bonnie++ bwm-ng mdadm btrfs-tools
    apt-get -yqq dist-upgrade
    apt-get -yqq autoremove
fi

eval $(get_cloud_cfg)

if [ "$CLOUD" = gce ]; then
    if [[ -e /etc/redhat-release ]]; then
        yum localinstall -y http://repo.xcalar.net/deps/gce-scripts-1.3.2-1.noarch.rpm
        yum localinstall -y http://repo.xcalar.net/deps/gcsfuse-0.20.1-1.x86_64.rpm
    fi
elif [ "$CLOUD" = aws ]; then
    if ! command -v ec2-tags; then
        curl -fsSL http://repo.xcalar.net/deps/ec2-tags-v3 > /usr/local/bin/ec2-tags-v3
        chmod +x /usr/local/bin/ec2-tags-v3
        ln -sfn ec2-tags-v3 /usr/local/bin/ec2-tags
    fi
elif [ "$CLOUD" = azure ]; then
    :
fi

getent group docker || groupadd -f -r -o -g 999 docker
getent group sudo || groupadd -f -r sudo
echo '%sudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-sudo && chmod 0440 /etc/sudoers.d/99-sudo

if test -n "$BUILD_CONTEXT"; then
    curl -sSL "$BUILD_CONTEXT" | tar zxvf -
fi
