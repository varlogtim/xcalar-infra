#!/bin/bash

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

get_metadata_value () {
    if test -e /usr/share/google/get_metadata_value; then
        /usr/share/google/get_metadata_value "$1"
    else
        curl -sSL -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/$1"
    fi
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
            $sh_c 'yum install -y nfs-utils curl'
            ;;
        ub*)
            export DEBIAN_FRONTEND=noninteractive
            $sh_c 'apt-get update -y'
            $sh_c 'apt-get install -y nfs-common curl'
            ;;
    esac
}

do_install

cd /tmp
NOW="$(date +'%Y%m%d-%H%M')"
IP="$(get_metadata_value network-interfaces/0/ip)"
HOSTNAME_F="$(get_metadata_value hostname)"
HOSTNAME_S="${HOSTNAME_F%%.*}"
HOSTSENTRY="$IP       $HOSTNAME_F $HOSTNAME_S  #xcalar_added"
CLUSTER="$(get_metadata_value attributes/cluster)"
if [ -z "$cluster" ]; then
    CLUSTER="${HOSTNAME%%-[0-9]*}"
fi
COUNT=$(get_metadata_value attributes/count)


CLUSTERDIR=/mnt/nfs/cluster/$CLUSTER
NFSMOUNT=/mnt/xcalar

$sh_c "cp /etc/hostname /etc/hostname.${NOW}"
$sh_c "echo $HOSTNAME_S > /etc/hostname"
$sh_c "cp /etc/hosts /etc/hosts.${NOW}"
$sh_c 'sed -i -e "/#xcalar_added$/d" /etc/hosts'
$sh_c 'sed -i -e "/'$IP'/d" /etc/hosts'
$sh_c "echo "$HOSTSENTRY" >> /etc/hosts"
$sh_c "hostname $HOSTNAME_S"

$sh_c 'mkdir -p /mnt/nfs /netstore/datasets'
$sh_c 'sed -i -e "/\/mnt\/nfs/d" /etc/fstab'
$sh_c 'sed -i -e "/\/netstore\/datasets/d" /etc/fstab'
$sh_c 'echo "nfs:/srv/share/nfs /mnt/nfs   nfs defaults 0   0" >> /etc/fstab'
$sh_c 'echo "nfs:/srv/datasets /netstore/datasets   nfs defaults 0   0" >> /etc/fstab'
$sh_c 'mount -a'

mkdir -p $CLUSTERDIR/members
$sh_c 'mkdir -m 0777 -p /var/opt/xcalar /var/opt/xcalar/stats'
$sh_c "mkdir -m 0777 $NFSMOUNT"
$sh_c "sed -i '/$CLUSTER/d' /etc/fstab"
$sh_c "echo 'nfs:/srv/share/nfs/cluster/$CLUSTER   $NFSMOUNT nfs defaults 0   0' >> /etc/fstab"
$sh_c 'mount -a'

#test -f /etc/hosts.orig || $sh_c 'cp /etc/hosts /etc/hosts.orig'
#(cat /etc/hosts.orig ; echo "$IP    $(hostname -f) $(hostname -s)") > /tmp/hosts && $sh_c 'mv /tmp/hosts /etc/hosts'
$sh_c "echo $HOSTSENTRY | tee $CLUSTERDIR/members/$HOSTNAME_F"
#$sh_c "echo '$IP   $(hostname -f) $(hostname -s)' | tee $CLUSTERDIR/members/$(hostname -f)"

# Download and run the installer
curl -sSL "$(get_metadata_value attributes/installer)" > /tmp/xcalar-installer
chmod +x /tmp/xcalar-installer
set +e
set -x
get_metadata_value attributes/config > /tmp/xcalar-config
sed -e 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath='$NFSMOUNT'@g' /tmp/xcalar-config > /tmp/xcalar-config-nfs
$sh_c 'mkdir -p /etc/xcalar'
$sh_c 'cp /tmp/xcalar-config-nfs /etc/xcalar/default.cfg'
$sh_c 'curl -sSL http://repo.xcalar.net/bysha1/f9/f986aa196ad7455880a25b60d2b69e4a9ad75dd5/XcalarLic.key > /etc/xcalar/XcalarLic.key'
$sh_c 'curl -sSL http://repo.xcalar.net/bysha1/4e/4eaac881c6194dbf4d768cd6df9f4e41bead6758/EcdsaPub.key > /etc/xcalar/EcdsaPub.key'
$sh_c 'bash -x /tmp/xcalar-installer --noStart'
$sh_c 'service rsyslog restart'
$sh_c 'service apache2 restart'
$sh_c 'service xcalar start'
