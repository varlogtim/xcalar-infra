#!/bin/bash

MOUNT=$1
shift
DISKS="$*"
MEMSIZEMB="$(free -m | awk '/Mem:/{print $2}')"

VMSIZE=$(curl -sH Metadata:True "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2017-08-01&format=text")
# Defaults file
mkdir -p /etc/default
cp ephemeral-disk /etc/default
echo "DISKS=\"$DISKS\"" >> /etc/default/ephemeral-disk
echo "LV_SWAP_SIZE=\"${MEMSIZEMB}M\"" >> /etc/default/ephemeral-disk

# Run scripts
mkdir -p /etc/ephemeral-scripts/
cp ephemeral-disk_start ephemeral-disk_stop /etc/ephemeral-scripts/

# Systemd units
cp ephemeral-data.mount  ephemeral-disk.service  ephemeral-units.service /etc/systemd/system/
cp xcalar.service /etc/systemd/system/

systemctl daemon-reload

systemctl enable ephemeral-disk.service
systemctl enable ephemeral-data.mount
systemctl enable ephemeral-units.service

systemctl start ephemeral-disk.service
systemctl start ephemeral-data.mount
systemctl start ephemeral-units.service


# Setup our deps repo
sed 's/enabled=1/enabled=0/g' xcalar-deps.repo > /etc/yum.repos.d/xcalar-deps.repo
cp RPM-GPG-KEY-Xcalar /etc/pki/rpm-gpg/RPM-GPG-KEY-Xcalar
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Xcalar
