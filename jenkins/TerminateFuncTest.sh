#!/bin/bash

_ssh () {                                                                       
    ssh -t -T -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}


set +e
                                                                       
HostArray=(${HostList//,/ })                                                       
for Host in "${HostArray[@]}"                                                      
do
_ssh  $Username@$Host "sudo pkill -9 gdbserver" 
_ssh  $Username@$Host "sudo pkill -9 python" 
_ssh  $Username@$Host "sudo pkill -9 usrnode" 
_ssh  $Username@$Host "sudo pkill -9 childnode"
done 

set -e
