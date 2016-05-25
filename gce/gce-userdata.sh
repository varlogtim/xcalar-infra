#!/bin/bash

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

os_version () {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            rhel)
                ELVERSION=$VERSION_ID
                echo rhel${ELVERSION}
                ;;
            centos)
                ELVERSION=$VERSION_ID
                echo el${ELVERSION}
                ;;
            ubuntu)
                UBVERSION="$(echo $VERSION_ID | cut -d'.' -f1)"
                echo ub${UBVERSION}
                ;;
            *)
                echo >&2 "Unknown OS version: $PRETTY_NAME ($VERSION)"
                return 1
                ;;
        esac
    elif [ -e /etc/redhat-release ]; then
        ELVERSION="$(grep -Eow '([0-9\.]+)' /etc/redhat-release | cut -d'.' -f1)"
        if grep -q 'Red Hat' /etc/redhat-release; then
                echo rhel${ELVERSION}
        elif grep -q CentOS /etc/redhat-release; then
                echo el${ELVERSION}
        fi
    else
        echo >&2 "Unknown OS version"
        return 1
    fi
}

do_install () {

    user="$(id -un 2>/dev/null || true)"

    sh_c='sh -c'
    if [ "$user" != 'root' ]; then
        if command_exists sudo; then
            sh_c='sudo -E sh -c'
        elif command_exists su; then
            sh_c='su -c'
        else
            cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
            exit 1
        fi
    fi

    curl=''
    if command_exists curl; then
        curl='curl -sSL'
    elif command_exists wget; then
        curl='wget -qO-'
    elif command_exists busybox && busybox --list-modules | grep -q wget; then
        curl='busybox wget -qO-'
    fi

    case "$(os_version)" in
        rhel*|el*)
            $sh_c 'yum update -y'
            $sh_c 'yum install -y nfs-utils'
            ;;
        ub*)
            export DEBIAN_FRONTEND=noninteractive
            $sh_c 'apt-get update -y'
            $sh_c 'apt-get install -y nfs-common'
            ;;
    esac
}

do_install

cd /tmp
IP="$(ifconfig eth0 | grep inet | awk '{print $2}' | awk -F':' '{print $2}')"
CLUSTER=$(/usr/share/google/get_metadata_value attributes/cluster)
if [ -z "$cluster" ]; then
    CLUSTER="${HOSTNAME%%-[0-9]*}"
fi
COUNT=$(/usr/share/google/get_metadata_value attributes/count)


CLUSTERDIR=/mnt/nfs/cluster/$CLUSTER
NFSMOUNT=/mnt/xcalar

$sh_c 'mkdir -p /mnt/nfs'
$sh_c 'sed -i "@/mnt/nfs@d" /etc/fstab'
$sh_c 'echo "nfs:/srv/share/nfs /mnt/nfs   nfs defaults 0   0" >> /etc/fstab'
$sh_c 'mount -a'

mkdir -p $CLUSTERDIR/members
$sh_c 'mkdir -m 0777 -p /var/opt/xcalar /var/opt/xcalar/stats'
$sh_c "mkdir -m 0777 $NFSMOUNT"
$sh_c "sed -i '/$CLUSTER/d' /etc/fstab"
$sh_c "echo 'nfs:/srv/share/nfs/cluster/$CLUSTER   $NFSMOUNT nfs defaults 0   0' >> /etc/fstab"
$sh_c 'mount -a'

test -f /etc/hosts.orig || $sh_c 'cp /etc/hosts /etc/hosts.orig'
(cat /etc/hosts.orig ; echo "$IP    $(hostname -f) $(hostname -s)") > /tmp/hosts && $sh_c 'mv /tmp/hosts /etc/hosts'
$sh_c "echo '$IP   $(hostname -f) $(hostname -s)' | tee $CLUSTERDIR/members/$(hostname -f)"

# Download and run the installer
curl -sSL "$(/usr/share/google/get_metadata_value attributes/installer)" > xcalar-installer
chmod +x ./xcalar-installer
set +e
set -x
/usr/share/google/get_metadata_value attributes/config > xcalar-config
sed -e 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath=nfs://'$NFSMOUNT'@g' xcalar-config > xcalar-config-nfs
$sh_c 'mkdir -p /etc/xcalar'
$sh_c 'cp xcalar-config-nfs /etc/xcalar/default.cfg'
$sh_c 'bash ./xcalar-installer'
$sh_c 'service xcalar start'
