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
    cat tmpl/${TMPL}.xml | ./modify-domain.py --name=$NAME --new-uuid --device-path=$IMAGE --mac-address=${MAC_ADDRESS[$ii]} > vm/${NAME}.xml
    virsh destroy $NAME 2>/dev/null || :
    virsh dumpxml $NAME &>/dev/null && virsh undefine $NAME
    sudo qemu-img create -f qcow2 -b $BASE $IMAGE
    virsh define vm/${NAME}.xml
    virsh start ${NAME}
done

