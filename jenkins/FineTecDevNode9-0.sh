#!/bin/bash

_ssh () {
    ssh -t -T -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}



res=$(_ssh root@$NODE "sudo python /netstore/users/xma/dashboard/git/xcalar-solutions/functest_dashboard/startFuncTests.py --testCase libstat::statsStress")
echo $res


sleep 10
