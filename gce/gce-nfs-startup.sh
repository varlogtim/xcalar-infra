#!/bin/bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server nfs-common
sudo service nfs-kernel-server stop || true
sudo mkdir -m 0755 -p /srv/share
sudo sed -i '@^/srv/share@d' /etc/exports
echo '/srv/share       *(rw,all_squash,sync,no_subtree_check)'  | tee -a /etc/exports
sudo service nfs-kernel-server start
sudo service apache2 stop || true
sudo service mysql stop || true
sudo update-rc.d nfs-kernel-service enable || true

if curl -sL http://repo.xcalar.net/scripts/gce-setup.sh /tmp/gce-setup.sh; then
   chmod +x /tmp/gce-setup.sh && /tmp/gce-setup.sh
fi
