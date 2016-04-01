#!/bin/bash
cd /tmp
IP="$(ifconfig eth0 | grep inet | awk '{print $2}' | awk -F':' '{print $2}')"
CLUSTER=$(/usr/share/google/get_metadata_value attributes/cluster)
if [ -z "$cluster" ]; then
    CLUSTER="${HOSTNAME%%-[0-9]*}"
fi
COUNT=$(/usr/share/google/get_metadata_value attributes/count)

sudo apt-get update -y
sudo apt-get install -y nfs-common
sudo mkdir -p /mnt/nfs
sudo sed -i "@/mnt/nfs@d" /etc/fstab
echo 'nfs:/srv/share/nfs /mnt/nfs   nfs defaults 0   0' | sudo tee -a /etc/fstab
sudo mount -a

CLUSTERDIR=/mnt/nfs/cluster/$CLUSTER

mkdir -p $CLUSTERDIR/members
sudo mkdir -m 0777 -p /var/opt/xcalar
sudo sed -i "/$CLUSTER/d" /etc/fstab
echo "nfs:/srv/share/nfs/cluster/$CLUSTER /var/opt/xcalar   nfs defaults 0   0" | sudo tee -a /etc/fstab
sudo mount -a

test -f /etc/hosts.orig || cp /etc/hosts /etc/hosts.orig
(cat /etc/hosts.orig ; echo "$IP	$(hostname -f) $(hostname -s)") | sudo tee /tmp/hosts && sudo mv /tmp/hosts /etc/hosts
echo "$IP	$(hostname -f) $(hostname -s)" | sudo tee $CLUSTERDIR/members/$(hostname -f)

# Download and run the installer
curl -sSL "$(/usr/share/google/get_metadata_value attributes/installer)" > xcalar-installer
chmod +x ./xcalar-installer
set +e
set -x
./xcalar-installer
/usr/share/google/get_metadata_value attributes/config > xcalar-config
sudo service xcalar stop || true
sudo killall childnode
sudo cp xcalar-config /etc/xcalar/default.cfg
sudo service xcalar start
