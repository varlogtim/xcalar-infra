#!/bin/bash

DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
TMPL="$1"
if [ -z "$TMPL" ]; then
    echo >&2 "Need to specify a template (el6-minimal, el7-minimal, ub14-minimal)"
    exit 1
fi
XML="$DIR/tmpl/${TMPL}.xml"
if ! test -e "$XML"; then
    echo >&2 "No template $XML found"
    exit 1
fi

BASE=/var/lib/libvirt/images/${TMPL}.qcow2

for ii in `seq 4`; do
    NAME=${TMPL}-${ii}
    IMAGE=$(dirname $BASE)/${NAME}.qcow2
    virsh destroy $NAME 2>/dev/null || :
done

