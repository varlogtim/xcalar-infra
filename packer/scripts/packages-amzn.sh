#!/bin/bash

set -x
export PS4='# ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]}() - [${SHLVL},${BASH_SUBSHELL},$?] '

curl -fsSL http://repo.xcalar.net/scripts/osid-201904 -o /usr/bin/osid
chmod +x /usr/bin/osid
OSID=${OSID:-$(osid)}

install_aws_deps() {
    local tmpdir="$(mktemp -d /tmp/aws.XXXXXX)"
    cd $tmpdir
    curl -L "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o awscli-bundle.zip
    unzip awscli-bundle.zip
    ./awscli-bundle/install -i /opt/aws -b /usr/local/bin/aws
    ln -sfn /opt/aws/bin/aws_completer /usr/local/bin/
    echo 'complete -C aws_completer aws' > /etc/bash_completion.d/awscli.sh
    cd - >/dev/null
    rm -rf "$tmpdir"
}

fix_cloud_init() {
    sed -i '/package-update-upgrade-install/d' /etc/cloud/cloud.cfg.d/00_defaults.cfg /etc/cloud/cloud.cfg
}


fix_uids() {
    # Amzn1 has UID_MIN and GID_MIN 500. Unbelievable
    sed -ir 's/^([UG]ID_MIN).*$/\1    1000/' /etc/login.defs
}

yum upgrade -y
yum install -y "https://storage.googleapis.com/repo.xcalar.net/xcalar-release-${OSID}.rpm"
yum erase -y 'ntp*'
yum install -y --enablerepo='xcalar*' --enablerepo=epel \
        chrony aws-cfn-bootstrap amazon-efs-utils ec2-net-utils ec2-utils \
        deltarpm curl wget tar gzip htop fuse jq nfs-utils iftop iperf3 sysstat python27-pip \
        lvm2 util-linux bash-completion nvme-cli nvmetcli python-pip libcgroup at

yum install -y --enablerepo='xcalar*' \
    ec2tools ephemeral-disk tmux ccache restic neovim xcalar-ssh-ca optgdb8 lifecycled opthaproxy2 consul node_exporter

yum groupinstall -y 'Development tools'

ephemeral-disk || true
lsblk
blkid

echo 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/aws/bin:/opt/mssql-tools/bin' > /etc/profile.d/path.sh
. /etc/profile.d/path.sh

case "$OSID" in
    amzn1)
        service chronyd start
        service atd start
        chkconfig chronyd on
        chkconfig atd on
        fix_uids
        yum install -y docker
        hash -r
        pip-2.7 install -U ansible
        ;;
    amzn2)
        systemctl enable --now chronyd
        systemctl enable --now atd
        amazon-linux-extras install -y ansible2=2.8 kernel-ng docker=latest vim
        yum install -y libcgroup-tools
        yum install consul nomad --enablerepo='xcalar-deps-common' -y
        ;;
esac
for prog in gdb gcore gdbserver; do
    ln -sfn /opt/gdb8/bin/${prog} /usr/local/bin/${prog}
    ln -sfn /opt/gdb8/bin/${prog} /usr/local/bin/${prog}8
done

install_aws_deps
fix_cloud_init

mkdir -p /etc/ansible
curl -fsSL https://raw.githubusercontent.com/ansible/ansible/devel/examples/ansible.cfg | \
    sed -r 's/^#?host_key_checking.*$/host_key_checking = False/g; s/^#?retry_files_enabled = .*$/retry_files_enabled = False/g' > /etc/ansible/ansible.cfg

for svc in xcalar puppet collectd consul docker node_exporter lifecycled; do
    if [ "$OSID" = amzn1 ]; then
        chkconfig ${svc} off || true
    elif [ "$OSID" = amzn2 ]; then
        systemctl disable ${svc} || true
    fi
done

rpm -q awscli && yum remove awscli -y || true
yum update -y

exit 0
