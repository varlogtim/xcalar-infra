#!/bin/bash

echo "Starting bootstrap at `date`"

INSTALLER_SERVER="https://zqdkg79rbi.execute-api.us-west-2.amazonaws.com/stable/installer"
HTML="http://pub.xcalar.net/azure/dev/html-4.tar.gz"
XCALAR_ADVENTURE_DATASET="http://pub.xcalar.net/datasets/xcalarAdventure.tar.gz"

CLUSTER="${HOSTNAME%%[0-9]*}"
INDEX="${2:-0}"
COUNT="${3:-1}"
LICENSE="$4"
NFSMOUNT="${5:-${CLUSTER}0:/srv/share}"
INSTALLER_URL="${6}"
ADMIN_USERNAME="${7}"
ADMIN_PASSWORD="${8}"
ADMIN_EMAIL="${9}"
STORAGE_ACCOUNT_NAME="${10}"
STORAGE_ACCESS_KEY="${11}"

echo "$ADMIN_USERNAME" >> /etc/adminUser
echo "$ADMIN_PASSWORD" >> /etc/adminUser
echo "$ADMIN_EMAIL" >> /etc/adminUser

# Safer curl. Use IPv4, follow redirects (-L), and add some retries. We've seen curl
# try to use IPv6 on AWS, and many intermittent errors when not retrying. --location
# to follow redirects is pretty much mandatory.
safe_curl () {
    curl -4 --location --retry 20 --retry-delay 3 --retry-max-time 60 "$@"
}

# Removes an entry from fstab
clean_fstab () {
    test -n "$1" && sed -i '\@'$1'@d' /etc/fstab
}

# mount_device /path /dev/partition will mount the given partition to the path. If
# the partition doesn't exist it is created from the underlying device. If the
# device is already mounted somewhere else, it is unmounted. *CAREFUL* when calling
# this function, it will destroy the specified device.
mount_device () {
    test $# -eq 2 || return 1
    test -n "$1" && test -n "$2" || return 1
    local PART= DEV="${2%[1-9]}" retry=
    if PART="$(set -o pipefail; findmnt -n $1 | awk '{print $2}')"; then
        local OLDMOUNT="$(findmnt -n $1 | awk '{print $1}')"
        if [ "$PART" != "$2" ] || [ -z "$OLDMOUNT" ]; then
            echo >&2 "Bad mount $1 on device $2. Bailing." >&2
            return 1
        fi
        umount $OLDMOUNT
    fi
    # If there's already a partition table, you need to sgdisk it twice
    # because it 'fails' the first time. sgdisk aligns the partition for you
    # -n1 creates an aligned partition using the entire disk, -t1 sets the
    # partition type to 'Linux filesystem' and -c1 sets the label to 'SSD'
    sgdisk -Zg -n1:0:0 -t1:8300 -c1:SSD $DEV || sgdisk -Zg -n1:0:0 -t1:8300 -c1:SSD $DEV
    test $? -eq 0 || return 1
    sync
    for retry in $(seq 5); do
        sleep 5
        # Must use -f[orce] because the partition may have already existed with a valid
        # file system. sgdisk doesn't earase the partitioning information, unlike parted/fdisk.
        mkfs.xfs -f $2 && break
    done
    test $? -eq 0 || return 1
    clean_fstab $2 && \
    mkdir -p $1 && \
    echo "$2   $1      xfs      defaults,relatime  0   0" | tee -a /etc/fstab
    mount $2
}


setenforce Permissive
sed -i -e 's/^SELINUX=enforcing.*$/SELINUX=permissive/g' /etc/selinux/config

yum update -y
yum install -y nfs-utils epel-release parted gdisk curl
yum install -y jq xfsprogs python-pip

pip install jinja2

test -n "$HTML" && safe_curl -sSL "$HTML" > html.tar.gz

tar -zxvf html.tar.gz

serveError() {
    errorMsg="$1"
    rectifyMsg="$2"
    cd html
    python ./render.py "$errorMsg" "$rectifyMsg"
    nohup python -m SimpleHTTPServer 80 >> /var/log/xcalarHttp.log 2>&1 &
}

# If INSTALLER_URL is provided, then we don't have to check the license
if [ -z "$INSTALLER_URL" ]; then
    retVal=`safe_curl -H "Content-Type: application/json" -X POST -d "{ \"licenseKey\": \"$LICENSE\", \"numNodes\": $COUNT, \"installerVersion\": \"latest\" }" $INSTALLER_SERVER`
    success=`echo "$retVal" | jq .success`
    if [ "$success" = "false" ]; then
        errorMsg=`echo "$retVal" | jq -r .error`
        echo 2>&1 "ERROR: $errorMsg"
        if [ "$errorMsg" = "License key not found" ]; then
            rectifyMsg="Please contact Xcalar at <a href=\"mailto:sales@xcalar.com\">sales@xcalar.com</a> for a trial license"
        else
            rectifyMsg="Please contact Xcalar support at <a href=\"mailto:support@xcalar.com\">support@xcalar.com</a>"
        fi
        serveError "$errorMsg" "$rectifyMsg"
        exit 1
    fi
    INSTALLER_URL=`echo "$retVal" | jq -r '.signedUrl'`
fi

# If on a single node instance, use the local host
# as the server
if [ -z "$NFSHOST" ] && [ "$COUNT" = 1 ]; then
    NFSMOUNT="${HOSTNAME}:/srv/share"
else
    NFSMOUNT="${CLUSTER}0:/srv/share"
fi

NFSHOST="${NFSMOUNT%%:*}"
SHARE="${NFSMOUNT##*:}"

if [ -r /etc/default/xcalar ]; then
    echo "" >> /etc/default/xcalar
    echo "## Azure Blob Storage config" >> /etc/default/xcalar
    echo "AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT_NAME" >> /etc/default/xcalar
    echo "AZURE_STORAGE_ACCESS_KEY=$STORAGE_ACCESS_KEY" >> /etc/default/xcalar
    . /etc/default/xcalar
fi

XCE_HOME="${XCE_HOME:-/mnt/xcalar}"
XCE_CONFIG="${XCE_CONFIG:-/etc/xcalar/default.cfg}"
XCE_LICENSEDIR="${XCE_LICENSEDIR:-/etc/xcalar}"

# Download the installer as soon as we can
safe_curl -sSL "$INSTALLER_URL" > installer.sh

# Determine our CIDR by querying the metadata service
safe_curl -H Metadata:True "http://169.254.169.254/metadata/instance?api-version=2017-04-02&format=json" | jq . > metadata.json
retCode=$?
if [ "$retCode" != "0" ]; then
    echo >&2 "ERROR: Could not contact metadata service"
    serveError "Could not contact metadata service" "Please contact Xcalar support at <a href=\"mailto:support@xcalar.com\">support@xcalar.com</a>"
    exit $retCode
fi

NETWORK="$(<metadata.json jq -r '.network.interface[].ipv4.subnet[].address')"
MASK="$(<metadata.json jq -r '.network.interface[].ipv4.subnet[].prefix')"
LOCALIPV4="$(<metadata.json jq -r '.network.interface[].ipv4.ipAddress[].privateIpAddress')"

# On some Azure instances /mnt/resource comes premounted but not aligned properly
mount_device /mnt/resource /dev/sdb1
LOCALSTORE=/mnt/resource

# Format and mount additional SSD, and prefer to use that
if test -b /dev/sdc; then
   mount_device /mnt/ssd  /dev/sdc1
   LOCALSTORE=/mnt/ssd
fi

# Create swapfile on local store, over using a partition. The speed is the
# same according to online docs
SWAPFILE=${LOCALSTORE}/swapfile
fallocate -l $(free -b | awk '/Mem:/{print $2}') $SWAPFILE
mkswap $SWAPFILE
clean_fstab $SWAPFILE
OLDecho "$SWAPFILE   none    swap    sw  0   0" | tee -a /etc/fstab
swapon $SWAPFILE

# Node 0 will host NFS shared storage for the cluster
if [ "$HOSTNAME" = "$NFSHOST" ]; then
    mkdir -p "${LOCALSTORE}/share" "$SHARE"
    clean_fstab "${LOCALSTORE}/share"
    echo "$LOCALSTORE/share    $SHARE   none   bind   0 0" | tee -a /etc/fstab
    mountpoint -q $SHARE || mount $SHARE
    # Ensure NFS is running
    systemctl enable rpcbind
    systemctl enable nfs-server
    systemctl enable nfs-lock
    systemctl enable nfs-idmap
    systemctl start rpcbind
    systemctl start nfs-server
    systemctl start nfs-lock
    systemctl start nfs-idmap

    # Export the share to everyone in our CIDR block and mark it
    # as world r/w
    mkdir -p "${SHARE}/xcalar"
    chmod 0777 "${SHARE}/xcalar"
    echo "${SHARE}/xcalar      ${NETWORK}/${MASK}(rw,sync,no_root_squash,no_all_squash)" | tee /etc/exports
    systemctl restart nfs-server
    if firewall-cmd --state; then
        firewall-cmd --permanent --zone=public --add-service=nfs
        firewall-cmd --reload
    fi
fi

if [ -f "installer.sh" ]; then
    if ! bash -x installer.sh --nostart; then
        echo >&2 "ERROR: Failed to run installer"
        serveError "Failed to run installer" "Please contact Xcalar support at <a href=\"mailto:support@xcalar.com\">support@xcalar.com</a>"
        exit 1
    fi
fi

# Generate a list of all cluster members
DOMAIN="$(dnsdomainname)"
MEMBERS=()
for NODEID in $(seq 0 $((COUNT-1))); do
    MEMBERS+=("${CLUSTER}${NODEID}")
done

# Generate /etc/xcalar/default.cfg
(
if [ $COUNT -eq 1 ]; then
    /opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - "$HOSTNAME"
else
    /opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - "${MEMBERS[@]}"
fi
# Enable ASUP on Cloud deployments
echo Constants.SendSupportBundle=true

# Custom SerDes path on local storage
XCE_XDBSERDESPATH="${LOCALSTORE}/serdes"
mkdir -m 0700 -p $XCE_XDBSERDESPATH && \
chown xcalar:xcalar $XCE_XDBSERDESPATH && \
echo Constants.XdbSerDesPath=$XCE_XDBSERDESPATH
) | tee "$XCE_CONFIG"

if ! test -e "${XCE_LICENSEDIR}/XcalarLic.key"; then
    echo "$LICENSE" > "${XCE_LICENSEDIR}/XcalarLic.key"
fi

# Make Xcalar config dir writable by xcalar user for config changes via XD
chown -R xcalar:xcalar /etc/xcalar

# Set up the mount for XcalarRoot
mkdir -p "$XCE_HOME"
clean_fstab $XCE_HOME
echo "${NFSMOUNT}/xcalar   $XCE_HOME    nfs     defaults    0   0" | tee -a /etc/fstab

sed -r -i -e 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath='$XCE_HOME'@g' "$XCE_CONFIG"

# Wait for Node0 NFS server to fully come up. Often times the other nodes get to this point before node0 has
# even begun
until mountpoint -q "$XCE_HOME"; do
    echo >&2 "Sleeping ... waiting $XCE_HOME"
    sleep 5
    mount "$XCE_HOME"
done

# Manage a stale NFS handle
until mkdir -p "${XCE_HOME}/members"; do
    umount "$XCE_HOME"
    mount "$XCE_HOME"
    echo >&2 "Sleeping ... waiting $XCE_HOME/members"
    sleep 5
done

echo "$LOCALIPV4        $(hostname -f)  $(hostname -s)" > "${XCE_HOME}/members/${INDEX}"
while :; do
    COUNT_ONLINE=$(find "${XCE_HOME}/members/" -type f | wc -l)
    echo >&2 "Have ${COUNT_ONLINE}/${COUNT} nodes online"
    if [ $COUNT_ONLINE -eq $COUNT ]; then
        break
    fi
    echo >&2 "Sleeping ... waiting for nodes"
    sleep 5
done

# Let's retrieve the xcalar adventure datasets now
if test -n "$XCALAR_ADVENTURE_DATASET"; then
    safe_curl -sSL "$XCALAR_ADVENTURE_DATASET" > xcalarAdventure.tar.gz
    tar -zxvf xcalarAdventure.tar.gz
    mkdir -p /netstore/datasets/adventure
    mv XcalarTraining /netstore/datasets/
    mv dataPrep /netstore/datasets/adventure/
    chmod -R 755 /netstore
fi

service xcalar start

# Add in the default admin user into Xcalar
if [ ! -z "$ADMIN_USERNAME" ]; then
    jsonData="{ \"defaultAdminEnabled: true\", \"username\": \"$ADMIN_USERNAME\", \"email\": \"$ADMIN_EMAIL\", \"password\": \"$ADMIN_PASSWORD\" }"
    echo "$jsonData" >> /etc/adminUser
    safe_curl -H "Content-Type: application/json" -X POST -d "$jsonData" "http://127.0.0.1/login/defaultAdmin/set"
fi
