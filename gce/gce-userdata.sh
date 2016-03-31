#!/bin/bash
sudo apt-get update -y
sudo apt-get install -y nfs-common
sudo mkdir -p /mnt/nfs
echo 'nfs:/srv/share/nfs /mnt/nfs   nfs defaults 0   0' | sudo tee -a /etc/fstab
sudo mount -a

cd /tmp
IP="$(ifconfig eth0 | grep inet | awk '{print $2}' | awk -F':' '{print $2}')"
echo "$IP   $(hostname -f) $(hostname -s)" | tee -a /etc/hosts
curl -sSL $(/usr/share/google/get_metadata_value attributes/installer) > xcalar-installer
chmod +x ./xcalar-installer
./xcalar-installer
CLUSTER=$(/usr/share/google/get_metadata_value attributes/cluster)
if [ -z "$cluster" ]; then
    CLUSTER="${HOSTNAME%%-[0-9]*}"
fi
mkdir -p /mnt/nfs/cluster/$CLUSTER
sudo mkdir -p /var/opt/xcalar
echo "nfs:/srv/share/nfs/cluster/$CLUSTER /var/opt/xcalar   nfs defaults 0   0" | sudo tee -a /etc/fstab
sudo mount -a
