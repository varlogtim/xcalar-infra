#!/bin/sh

# Store build time
date > /etc/vagrant_box_build_time

if ! id vagrant >/dev/null; then
    useradd -m -s /bin/bash vagrant
fi

# Set up sudo
echo 'vagrant ALL=NOPASSWD:ALL' > /etc/sudoers.d/vagrant

# Install vagrant key
mkdir -pm 700 /home/vagrant/.ssh
wget --no-check-certificate https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub -O /home/vagrant/.ssh/authorized_keys
chmod 0600 /home/vagrant/.ssh/authorized_keys
chown -R vagrant:vagrant /home/vagrant/.ssh

# NFS used for file syncing
apt-get --yes install nfs-common
