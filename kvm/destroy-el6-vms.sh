#!/bin/bash

TMPL=el6-minimal
BASE=/var/lib/libvirt/images/${TMPL}.qcow2

MAC_ADDRESS=(
0
00:16:3e:62:c0:01
00:16:3e:15:86:30
00:16:3e:f0:9d:9b
00:16:3e:6c:50:c7
)

for ii in `seq 4`; do
    NAME=${TMPL}-${ii}
    IMAGE=$(dirname $BASE)/${NAME}.qcow2
    virsh destroy $NAME 2>/dev/null || :
done

