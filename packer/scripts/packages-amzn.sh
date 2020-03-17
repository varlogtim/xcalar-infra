#!/bin/bash

set -ex

export PS4='# $(date +%FT%TZ) ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]}() - [${SHLVL},${BASH_SUBSHELL},$?] '

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

install_ssm_agent() {
    yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm || true
    if [ $(osid -i) == "systemd" ]; then
        systemctl daemon-reload
        systemctl enable amazon-ssm-agent.service || true
    else
        status amazon-ssm-agent || true
    fi
}

install_osid() {
    curl -fsSL http://repo.xcalar.net/scripts/osid-20191219 -o /usr/bin/osid
    chmod +x /usr/bin/osid
    OSID=${OSID:-$(osid)}
}

fix_cloud_init() {
    sed -i '/package-update-upgrade-install/d' /etc/cloud/cloud.cfg.d/* /etc/cloud/cloud.cfg || true
}


fix_uids() {
    # Amzn1 has UID_MIN and GID_MIN 500. Unbelievable
    sed -r -i 's/^([UG]ID_MIN).*$/\1    1000/' /etc/login.defs
}

install_gdb8() {
    yum install -y optgdb8 --enablerepo='xcalar*'
    for prog in gdb gcore gdbserver; do
        ln -sfn /opt/gdb8/bin/${prog} /usr/local/bin/${prog}
        ln -sfn /opt/gdb8/bin/${prog} /usr/local/bin/${prog}8
    done
}

fix_networking() {
    (
    cat > /etc/sysconfig/network <<-EOF
	NETWORKING=yes
	HOSTNAME=localhost.localdomain
	NOZEROCONF=yes
	EOF
    cd /etc/sysconfig/network-scripts
    cat > ifcfg-eth0 <<-EOF
	DEVICE=eth0
	BOOTPROTO=dhcp
	ONBOOT=yes
	TYPE=Ethernet
	USERCTL=yes
	PEERDNS=yes
	DHCPV6C=no
	IPV6INIT=no
	PERSISTENT_DHCLIENT=yes
	RES_OPTIONS="timeout:2 attempts:5"
	DHCP_ARP_CHECK=no
	EOF
    #sed 's/eth0/eth1/; s/^ONBOOT=.*/ONBOOT=no/' ifcfg-eth0 > ifcfg-eth1
    )
}

install_lego() {
    curl -L https://github.com/go-acme/lego/releases/download/v3.3.0/lego_v3.3.0_linux_amd64.tar.gz | tar zxvf - -C /usr/local/bin
    setcap cap_net_bind_service=+ep /usr/local/bin/lego
}

install_sysdig() {
    curl -s https://s3.amazonaws.com/download.draios.com/stable/install-sysdig | bash
}

install_osid
install_lego
#fix_networking

echo 'exclude=kernel-debug* *.i?86 *.i686' >> /etc/yum.conf
yum upgrade -y
yum install -y "https://storage.googleapis.com/repo.xcalar.net/xcalar-release-${OSID}.rpm" || true
yum clean all --enablerepo='*'
yum erase   -y 'ntp*' || true

yum install -y --enablerepo='xcalar*' --enablerepo=epel \
        chrony aws-cfn-bootstrap amazon-efs-utils ec2-net-utils ec2-utils \
        deltarpm curl wget tar gzip htop fuse jq nfs-utils iftop iperf3 sysstat python27-pip \
        lvm2 util-linux bash-completion nvme-cli nvmetcli libcgroup at python27-devel \
        libnfs-utils

yum install -y --enablerepo='xcalar*' --enablerepo='epel' --disableplugin=priorities \
    ec2tools ephemeral-disk tmux ccache restic lifecycled consul node_exporter \
    freetds xcalar-node10 java-1.8.0-openjdk-headless opthaproxy2 su-exec tini

yum remove -y python26 python-pip || true

sed -r -i 's/^#?LV_SWAP_SIZE=.*$/LV_SWAP_SIZE=MEMSIZE2X/; s/^#?LV_DATA_EXTENTS=.*$/LV_DATA_EXTENTS=100%FREE/; s/^#?ENABLE_SWAP=.*/ENABLE_SWAP=1/' /etc/sysconfig/ephemeral-disk
ephemeral-disk || true

yum groupinstall -y 'Development tools'

lsblk
blkid

echo 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/aws/bin:/opt/mssql-tools/bin' > /etc/profile.d/path.sh
. /etc/profile.d/path.sh
install_ssm_agent

case "$OSID" in
    amzn1)
        service chronyd start
        service atd start
        echo manual | tee /etc/init/consul.override
        echo manual | tee /etc/init/node_exporter.override
        echo manual | tee /etc/init/lifecycled.override

        mkdir -p /run
        echo 'tmpfs  /run   tmpfs   defaults    0   0' >> /etc/fstab

        chkconfig chronyd on
        chkconfig atd on
        fix_uids
        hash -r
        pip-2.7 --no-cache-dir install -U ansible
        install_gdb8
        ;;
    amzn2)
        systemctl enable --now chronyd
        systemctl enable --now atd
        systemctl disable update-motd.service || true
        #chkconfig network off || true
        #systemctl mask network.service || true
        amazon-linux-extras install -y ansible2=2.8 kernel-ng vim
        yum install -y libcgroup-tools
        systemctl set-default multi-user.target
        #yum install -y NetworkManager
        #systemctl enable --now NetworkManager.service
        ;;
esac

install_aws_deps
install_sysdig
fix_cloud_init

mkdir -p /etc/ansible
curl -fsSL https://raw.githubusercontent.com/ansible/ansible/devel/examples/ansible.cfg | \
    sed -r 's/^#?host_key_checking.*$/host_key_checking = False/g; s/^#?retry_files_enabled = .*$/retry_files_enabled = False/g' > /etc/ansible/ansible.cfg

for svc in xcalar puppet collectd consul node_exporter lifecycled update-motd; do
    if [ "$OSID" = amzn1 ]; then
        if test -e /etc/init/${svc}.conf; then
            echo manual > /etc/init/${svc}.override
        else
            chkconfig ${svc} off || true
        fi
    elif [ "$OSID" = amzn2 ]; then
        systemctl disable ${svc} || true
    fi
done

rpm -q awscli && yum remove awscli -y || true
yum update -y

exit 0
