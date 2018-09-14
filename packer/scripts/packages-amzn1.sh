#!/bin/bash

install_puppet() {
    REPOPKG=puppetlabs-release-pc1-el-6.noarch.rpm
    yum install -y http://yum.puppetlabs.com/$REPOPKG
    yum install -y puppet-agent
}

install_aws_deps() {
    curl -L "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o awscli-bundle.zip
    unzip awscli-bundle.zip
    ./awscli-bundle/install -i /opt/aws -b /usr/local/bin/aws
    rm -rf awscli-bundle*
    yum install -y https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.amzn1.noarch.rpm
    yum install -y --enablerepo='xcalar*' --enablerepo=epel ephemeral-disk ec2tools
}

install_java() {
    yum remove -y java-1.7.0-openjdk-headless java-1.7.0-openjdk || true
    yum install -y java-1.8.0-openjdk-devel
    cat > /etc/profile.d/zjava.sh <<'EOF'
export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk.x86_64
export PATH="$JAVA_HOME/bin:$PATH"
EOF
}

fix_cloud_init() {
    sed -i '/package-update-upgrade-install/d' /etc/cloud/cloud.cfg.d/00_defaults.cfg
}

yum install -y http://repo.xcalar.net/xcalar-release-amzn1.rpm
yum install -y epel-release yum-utils
install_aws_deps
install_java
fix_cloud_init

yum install --enablerepo='epel' --enablerepo='xcalar*' -y deltarpm curl wget tar gzip collectd htop gdb fuse jq amazon-efs-utils nfs-utils ansible iftop
sed -i -r 's/^#?host_key_checking.*$/host_key_checking = False/g; s/^#?retry_files_enabled = .*$/retry_files_enabled = False/g' /etc/ansible/ansible.cfg
yum groupinstall -y 'Development tools'
yum install -y --enablerepo=epel fuse iperf3 tmux htop sysstat
yum remove -y nodejs npm || true
curl  -sSL https://rpm.nodesource.com/setup_6.x | bash -
echo 'export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/opt/xcalar/bin:/opt/aws/bin:/bin' > /etc/profile.d/paths.sh
. /etc/profile.d/paths.sh

yum install -y nodejs
npm install -g aws-sdk

for svc in xcalar puppet collectd; do
    chkconfig ${svc} off || true
done
