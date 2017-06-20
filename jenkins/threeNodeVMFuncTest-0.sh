#!/bin/bash

_ssh () {                                                                       
    ssh -t -T -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}

 
                                                                     
HostArray=(${HostList//,/ })
numNode=${#HostArray[@]}
counter=0


PIDS=()                                                                         
                                                                                



for Hostname in "${HostArray[@]}"                                                      
do
    if [ $counter -eq 0 ]; then
        _ssh  $Username@$Hostname "cp $ConfigFile $ConfigFile-copy"
        echo "$FuncTestParam" | _ssh $Username@$Hostname "cat >> $ConfigFile-copy"
    fi
    
    set +e
    _ssh $Username@$Hostname "find /home/jenkins/xcalar -name "core.childnode*" -print0 | xargs -0 rm"
    _ssh $Username@$Hostname "find /home/jenkins/xcalar -name "core.usrnode*" -print0 | xargs -0 rm"
    _ssh $Username@$Hostname "sudo pkill -9 gdbserver"
    _ssh $Username@$Hostname "sudo pkill -9 usrnode"
    _ssh $Username@$Hostname "sudo pkill -9 childnode"
    
    sleep 10s
    
    _ssh $Username@$Hostname "ps aux | grep [u]srnode"
    if [ $? -eq 0 ]; then
        echo "fail to kill usrnode"
        exit 1
    fi
    
    _ssh $Username@$Hostname "sudo rm -rf /dev/shm/*"
 
    set -e
    
    

    if [ $TestFromList == "true" ]; then
    
        Test=$TestCase
    else
        Test=$TestList    
    fi
    
    _ssh $Username@$Hostname "$ScriptPath --testList $Test --numNode $numNode --nodeId $counter --configFile $ConfigFile-copy" &> /dev/null &
    
    PIDS+=($!) 
     counter=$(($counter + 1))
done     

                                                                        
                                                                                
wait ${PIDS[@]} 


