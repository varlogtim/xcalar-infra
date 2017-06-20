#!/bin/bash

_ssh () {
    ssh -t -T -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}

num=$(_ssh $Username@$Hostname 'ps -ef | grep dashboard | grep -v grep | wc -l')
if [[ $num == 0 ]];
then echo "no dashboard program, continuing";
else echo "dashboard program is already running, please terminate it before restarting the tests"; exit 1;
fi

set +e
_ssh $Username@$Hostname "find /home/jenkins/xcalar -name "core.childnode*" -print0 | xargs -0 rm"
_ssh $Username@$Hostname "find /home/jenkins/xcalar -name "core.usrnode*" -print0 | xargs -0 rm"
_ssh $Username@$Hostname "ps -ef | grep \"startFuncTests.p[y]\" | awk '{print \$2}' | sudo xargs -r kill -9"
_ssh $Username@$Hostname "sudo pkill -9 gdbserver"
_ssh $Username@$Hostname "sudo pkill -9  usrnode"
_ssh $Username@$Hostname "sudo pkill -9 childnode"
set -e

_ssh $Username@$Hostname "cp $ConfigFile $ConfigFile-copy"
echo "$FuncTestParam" | _ssh $Username@$Hostname "cat >> $ConfigFile-copy"

_ssh $Username@$Hostname "$ScriptPath $ScriptParameter $ConfigFile-copy"
