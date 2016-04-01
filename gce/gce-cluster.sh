#!/bin/bash

say () {
    echo >&2 "$*"
}

if [ -z "$1" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "usage: $0 <installer-url> <count (default: 3)> <cluster (default: `whoami`-xcalar)>" >&2
    exit 1
fi
DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
INSTALLER="${1}"
INSTALLER_FNAME="$(basename $INSTALLER)"
COUNT="${2:-3}"
CLUSTER="${3:-`whoami`-xcalar}"
CONFIG=/tmp/$CLUSTER-config.cfg
UPLOADLOG=/tmp/$CLUSTER-manifest.log
WHOAMI="$(whoami)"
EMAIL="$(git config user.email)"
INSTANCES=($(set -o braceexpand; eval echo $CLUSTER-{1..$COUNT}))
if test -f "$INSTALLER"; then
    INSTALLER_URL="repo.xcalar.net/builds/$INSTALLER_FNAME"
    if ! gsutil ls gs://$INSTALLER_URL &>/dev/null; then
        say "Uploading $INSTALLER to gs://$INSTALLER_URL"
        until gsutil -m -o GSUtil:parallel_composite_upload_threshold=100M \
                     cp -c -L "$UPLOADLOG" \
                     "$INSTALLER" gs://$INSTALLER_URL; do
            sleep 1
        done
        mv $UPLOADLOG $(basename $UPLOADLOG .log)-finished.log
    else
        say "$INSTALLER_URL already exists. Not uploading."
    fi
    INSTALLER=http://${INSTALLER_URL}
fi

if [[ "${INSTALLER}" =~ ^http:// ]]; then
    if ! curl -Is "${INSTALLER}" | head -n 1 | grep -q '200 OK'; then
        say "Unable to access ${INSTALLER}"
        exit 1
    fi
elif [[ "${INSTALLER}" =~ ^gs:// ]]; then
    if ! gsutil ls "${INSTALLER}" &>/dev/null; then
        say "Unable to access ${INSTALLER}"
        exit 1
    fi
else
    say "WARNING: Unknown protocol ${INSTALLER}"
fi

rm -f $CONFIG
$DIR/../bin/genConfig.sh $DIR/../bin/template.cfg $CONFIG ${INSTANCES[@]}


say "Launching ${#INSTANCES[@]} instances: ${INSTANCES[@]} .."
set -x
gcloud compute instances create ${INSTANCES[@]} \
    --image ${IMAGE:-xcbuilder-ubuntu-1404-1458251279} \
    --zone ${ZONE:-us-central1-f} \
    --machine-type ${INSTANCE_TYPE:-n1-standard-4} \
    --network=private \
    --metadata "installer=$INSTALLER,count=$COUNT,cluster=$CLUSTER,owner=$WHOAMI,email=$EMAIL" \
    --metadata-from-file user-data=$DIR/gce-userdata.sh,config=$CONFIG \
    --preemptible
