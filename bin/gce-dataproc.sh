#!/bin/bash

set -e

IMAGE='1.3-deb9'
FRULE='sparkport'

usage()
{
    cat << EOF
    Create Dataproc Cluster within GCE.

    Example invocation:
        $myName -c my-cluster-test -m n1-standard-4 -n 3 -w n1-standard-4 -S 500 -s 500 -z us-central1-a -b bucket-name-store-data

        -c <name>       GCE cluster name
        -m <type>       Master instance type (eg n1-standard-8)
        -n <nodes>      Number of woker in cluster
        -w <type>       Worker instance type (eg n1-standard-8)
        -S <size>       Master disk siez(GB)
        -s <size>       Worker disk size(GB)
        -z <zone>       Zone
        -b <bucket>     Bucket to store the data
        -f <fire rule>  Fire Rule Name to set port 10000 open, dafault name "sparkport"
EOF
}

while getopts "c:m:n:w:S:s:z:b:f:" opt; do
  case $opt in
      c) CLUSTERNAME="$OPTARG";;
      m) MASTER_TYPE="$OPTARG";;
      n) NUM_WORKER="$OPTARG";;
      w) WORKER_TYPE="$OPTARG";;
      S) MASTER_DISK_SIZE="$OPTARG";;
      s) WORKER_DISK_SIZE="$OPTARG";;
      z) ZONE="$OPTARG";;
      b) BUCKET="$OPTARG";;
      f) FRULE="$OPTARG";;
      *) usage; exit 0;;
  esac
done

getMasterIp() {
    gcloud compute instances describe "${CLUSTERNAME}-m" \
        --format='value[](networkInterfaces.accessConfigs.natIP)' \
        | python -c 'import sys; print(eval(sys.stdin.readline())[0]);'
}

rcmd() {
    args="$@"
    gcloud compute ssh "$CLUSTERNAME-m" --command "$args"
}

setSparkServer(){
    rcmd sudo service hive-server2 stop
    rcmd sudo -u spark /usr/lib/spark/sbin/start-thriftserver.sh
}

cleanup () {
    gcloud dataproc clusters delete $CLUSTERNAME
}

die () {
    cleanup
    say "ERROR($1): $2"
    exit $1
}

gcloud dataproc clusters create ${CLUSTERNAME} --bucket ${BUCKET} --subnet default --zone ${ZONE} \
    --master-machine-type ${MASTER_TYPE} \
    --master-boot-disk-size ${MASTER_DISK_SIZE} \
    --num-workers ${NUM_WORKER} \
    --worker-machine-type ${WORKER_TYPE} \
    --worker-boot-disk-size ${WORKER_DISK_SIZE} \
    --image-version $IMAGE \
    --scopes 'https://www.googleapis.com/auth/cloud-platform' \
    --tags http-server,https-server

res=${PIPESTATUS[0]}
if [ "$res" -ne 0 ]; then
    die $res "Failed to create some instances"
fi

gcloud compute firewall-rules create ${FRULE} --direction=INGRESS --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:10000 \
    --source-ranges=0.0.0.0/0

setSparkServer
getMasterIp


