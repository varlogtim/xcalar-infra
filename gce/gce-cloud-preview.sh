#!/bin/bash
export CLOUDSDK_COMPUTE_REGION=${CLOUDSDK_COMPUTE_REGION-us-central1}
export CLOUDSDK_COMPUTE_ZONE=${CLOUDSDK_COMPUTE_ZONE-us-central1-f}
GCLOUD_SDK_URL="https://sdk.cloud.google.com"

NAME="$(basename ${BASH_SOURCE[0]} .sh)"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XLRINFRA="$(cd "$DIR/.." && pwd)"

INSTALLER="${INSTALLER:-/netstore/builds/byJob/BuildTrunk/xcalar-latest-installer-prod}"
COUNT="${COUNT:-1}"
CLUSTER="${CLUSTER:-preview-`whoami`-xcalar}"
URL=""
export TTL="${TTL:-120}"
export ZONE="${ZONE:-xcalar-cloud}"
export DOMAIN="${DOMAIN:-xcalar.cloud}"
export NOTPREEMPTIBLE="${NOTPREEMPTIBLE:-1}"
export DRYRUN="${DRYRUN:-0}"
export IMAGE="${IMAGE:-ubuntu-1404-lts-1485895114}"
export XC_DEMO_DATASET_DIR="${XC_DEMO_DATASET_DIR:-/srv/datasets}"
export ACME_CA="${ACME_CA:-https://acme-v01.api.letsencrypt.org/directory}"


syslog () {
    logger -t "$NAME" -i -s "$@"
}

die () {
    local rc=$1
    shift
    syslog "ERROR($rc): $*"
    exit $rc
}


say () {
    echo >&2 "$*"
}

usage () {
    cat >&2 <<XEOF

    usage: $0 [-i <installer-url (default: $INSTALLER)> [-n <count (default: $COUNT)>] [-c <cluster (default: $CLUSTER)>] [-u <dns-short-name (default: $CLUSTER)>] [-s use the staging CA]

    IMAGE=$IMAGE
    NOTPREEMPTIBLE=$NOTPREEMPTIBLE

    TTL=$TTL
    ZONE=$ZONE
    DOMAIN=$DOMAIN
    DRYRUN=$DRYRUN
    ACME_CA=$ACME_CA

XEOF
    exit 1
}

get_dns_entry () {
    local dnsip=
    dnsip="$(set -o pipefail; dig @8.8.8.8 ${1} | egrep '^'${1}'.\s+([-0-9]+)\s+IN\s+A\s+' | awk '{print $(NF)}')"
    local rc=$?
    if [ $rc -ne 0 ] || [ "$dnsip" = "" ]; then
        return 1
    fi
    echo "$dnsip"
    return 0
}

gce_dns_remove () {
    local curip=
    curip="$(get_dns_entry ${1}.${DOMAIN})"
    if [ $? -ne 0 ] || [ "$curip" = "" ]; then
        return 1
    fi
    "$DIR/gce-dns.sh" remove "$1" "$curip"
}

gce_dns_replace () {
    syslog "Removing $1 DNS entry, if any"
    gce_dns_remove "$1" || true
    syslog "Adding DNS entry $*"
    "$DIR/gce-dns.sh" add "$@"
}


while getopts "hi:n:c:u:s" opt "$@"; do
    case "$opt" in
        i) INSTALLER="$OPTARG";;
        n) COUNT="$OPTARG";;
        c) CLUSTER="$OPTARG";;
        u) URL="$OPTARG";;
        s) export ACME_CA="https://acme-staging.api.letsencrypt.org/directory";;
        h) usage;;
        \?) say "Invalid option -$OPTARG"; exit 1;;
        :) say "Option -$OPTARG requires an argument."; exit 1;;
    esac
done

if ! echo "$CLUSTER" | egrep -q '^preview-[a-z0-9\.-]+[a-z0-9]$'; then
    die 3 "Your cluster name must match with 'preview-[a-z0-9.-]+[a-z0-9]$'"
fi

export TMPDIR="${TMPDIR:-/tmp/$(id -u)}/$(basename ${BASH_SOURCE[0]} .sh)"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

set +e

syslog "Launching cluster $CLUSTER with $COUNT instances using installer $INSTALLER"
(set -o pipefail; $DIR/gce-cluster.sh "$INSTALLER" $COUNT "$CLUSTER" 2>&1 | tee "$TMPDIR/gce-cluster.log")
rc=$?
if [ $rc -ne 0 ]; then
    die $rc "Failed to launch cluster"
fi

gcloud compute instances list > "$TMPDIR/gce-instances.tsv"

IPS=()
for ii in $(seq 1 $COUNT); do
    instance="${CLUSTER}-${ii}"
    dnsname="${instance}.${DOMAIN}"
    ip="$(awk "/^$instance/{print \$(NF-1)}" "$TMPDIR/gce-instances.tsv")"
    if [ $? -eq 0 ] && [ -n "$ip" ]; then
        IPS+=($ip)
        gce_dns_replace "$instance" "$ip"
        if [ $ii -eq 1 ]; then
            if [ -n "$URL" ] && [ "$instance" != "${URL}" ]; then
                gce_dns_replace "$URL" "$ip"
            fi
        fi
    else
        die 1 "Failed to get IP of $instance"
    fi
    # Wait until the script can ssh into the instance
    until gcloud compute ssh "$instance" -- "exit 0"; do
        sleep 5
    done
    # tar up $XLRINFA/bin and deploy it to /var/tmp/gce-cloud-preview on the instance
    (cd $XLRINFRA && tar cf - bin) | gcloud compute ssh "$instance" -- "mkdir -p /var/tmp/$NAME && cd /var/tmp/$NAME && tar xf -"
done

for ii in $(seq 1 $COUNT); do
    instance="${CLUSTER}-${ii}"
    dnsname="${instance}.${DOMAIN}"
    ip="$(awk "/^$instance/{print \$(NF-1)}" "$TMPDIR/gce-instances.tsv")"
    until gcloud compute ssh "$instance" -- "sudo grep 'All nodes now network ready' /var/log/Xcalar.log"; do
        sleep 5
    done
    if [ $ii -eq 1 ] && [ -n "$URL" ] && [ "$instance" != "$URL" ]; then
        gcloud compute ssh "$instance" -- "sudo ACME_CA=$ACME_CA /var/tmp/$NAME/bin/install-caddy.sh ${URL}.${DOMAIN}"
    else
        gcloud compute ssh "$instance" -- "sudo ACME_CA=$ACME_CA /var/tmp/$NAME/bin/install-caddy.sh $dnsname"
    fi
    gcloud compute ssh $instance --ssh-flag="-tt" --command "echo export XC_DEMO_DATASET_DIR=$XC_DEMO_DATASET_DIR | sudo tee -a /etc/default/xcalar" && \
    gcloud compute ssh $instance --ssh-flag="-tt" --command "sudo sed -i -e 's@^Constants.XcalarRootCompletePath=.*\$@Constants.XcalarRootCompletePath=/var/opt/xcalar@g' /etc/xcalar/default.cfg" && \
    gcloud compute ssh $instance --ssh-flag="-tt" --command "sudo service xcalar stop-supervisor || true" && \
    gcloud compute ssh $instance --ssh-flag="-tt" --command "sudo service xcalar start"
    rc=$?
    if [ $rc -ne 0 ]; then
        die 2 "Failed to install caddy"
    fi
done
