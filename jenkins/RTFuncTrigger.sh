#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$HOME/google-cloud-sdk/bin:$PATH"
USER=root

_ssh () {
    ssh -t -T -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}



set +e                                                                                                                            
_ssh  $USER@$NODE "sudo pkill -9 gdbserver" 
_ssh  $USER@$NODE "sudo pkill -9 python" 
_ssh  $USER@$NODE "sudo pkill -9 usrnode" 
_ssh  $USER@$NODE "sudo pkill -9 childnode"
set -e


num=$(_ssh $USER@$NODE 'ps -ef | grep dashboard | grep -v grep | wc -l')
if [[ $num == 0 ]]; 
then echo "no dashboard program, continuing"; 
else echo "dashboard program is already running, please terminate it before restarting the tests"; exit 1; 
fi


#stop usrnode remotely
_ssh $USER@$NODE "service xcalar stop" < /dev/null || true

#build debug
build clean
build config
build


_scp () {
   scp -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}


#copy over binaries and scripts
_scp -r $XLRDIR/bin $USER@$NODE:/opt/xcalar/
_scp -r $XLRDIR/scripts $USER@$NODE:/opt/xcalar/

_scp $XLRDIR/src/lib/libfaulthandler/.libs/libfaulthandler.so.0 $USER@$NODE:/opt/xcalar/lib/libfaulthandler.so.0

#start usrnode remotely
_ssh $USER@$NODE "service xcalar start" < /dev/null || true


timeOut=600                                                                         
                                                                                   
counter=0                                                                          
set +e
while true; do                                                                     
                                                                                   
    _ssh $USER@$NODE "/opt/xcalar/bin/xccli -c \"version\" | grep \"Backend Version\"" < /dev/null
                                                                                   
    if [ $? -eq 0 ]; then                                                          
        break                                                                      
    fi                                                                             
                                                                                   
    sleep 5s                                                                       
    counter=$(($counter + 5))                                                      
    if [ $counter -gt $timeOut ]; then                                             
        exit 1                                                                     
    fi                                                                             
done  
set -e

_ssh $USER@$NODE "sudo echo \"kernel.core_pattern = /cores/core.%e.%p\" > /etc/sysctl.d/99-xcalar.conf && sudo sysctl -p /etc/sysctl.d/99-xcalar.conf"

_ssh $USER@$NODE "sudo df -h"
_ssh $USER@$NODE "time /opt/xcalar/bin/xccli -c 'version'"


echo "usrnode PIDs"
_ssh $USER@$NODE "sudo ps -ef | grep bin/usrnode | grep -v grep | awk '"'"'{print $2}'"'"'"

#num_threads=$(_ssh $USER@$NODE 'sudo -E gdb -p $(ps -ef | grep usrnode | grep -v grep | awk '"'"'{print $2}'"'"' | head -1) -batch -ex '"'"'thread apply all bt'"'"' /opt/xcalar/bin/usrnode | grep Thread | grep LWP | wc -l')
#echo "Before run, num of threads = "$num_threads

TestStr=""                                                                         
TestArray=(${TestList//,/ })                                                       
for Test in "${TestArray[@]}"                                                      
do                                                                                 
TestStr="$TestStr --testCase $Test"
done

_ssh $USER@$NODE "cp $ConfigFile-copy $ConfigFile"

echo "$FuncTestParam" | _ssh $USER@$NODE "cat >> $ConfigFile"


_ssh jenkins@$NODE "python $ScriptPath $TestStr --cliPath /opt/xcalar/bin/xccli --cfgPath $ConfigFile &> /dev/null &"


#_ssh $USER@$NODE "sudo find /var/opt/xcalar/export/ -name "exportFile-*" -print0 | sudo xargs -0 rm -rf"
