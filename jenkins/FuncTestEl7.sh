#!/bin/bash

set +e

num=$(ssh -t -T -o StrictHostKeyChecking=no jenkins@functest-el7-1 'ps -ef | grep dashboard | grep -v grep | wc -l')
if [[ $num == 0 ]];
then echo "no dashboard program, continuing";
else echo "dashboard program is already running, please terminate it before restarting the tests"; exit 1;
fi

echo "THIS SCRIPT SHOULD ONLY BE TRIGGERED ONCE. YOU WILL NEED TO MANUALLY KILL THE SCRIPT ON functest-el7-1 HOST BEFORE YOU RUN THIS AGAIN, WE DO NOT HAVE A JENKINS KILL SCRIPT"
echo "THIS IS HOW IT WILL LOOK ON THE HOST"
ssh -t -T -o StrictHostKeyChecking=no jenkins@functest-el7-1 "time /opt/xcalar/bin/xccli -c 'version'"

ssh -t -T -o StrictHostKeyChecking=no jenkins@functest-el7-1 'python /netstore/users/xma/dashboard/startFuncTests.py \
--testCase libkvstore::kvStoreStress \
--testCase liblog::logStress \
--testCase libqueryparser::queryParserStress \
--testCase libqueryeval::queryEvalStress \
--testCase libns2::ns2Test \
--testCase libqm::qmStringQueryTest \
--testCase libqm::qmRetinaQueryTest \
--testCase libdag::randomTest \
--testCase libstat::statsStress \
--testCase libmsg::msgStress \
--testCase libdag::sanityTest \
--testCase liboptimizer::optimizerStress \
--testCase libruntime::custom \
--testCase liblocalmsg::sanity \
--testCase libcallout::threads \
--testCase libcallout::cancelStarvation \
--testCase libbc::bcStress \
--testCase libsession::sessionStress \
--testCase libds::dataSetStress \
--testCase libxdb::xdbStress \
--testCase liboperators::basicFunc \
--testCase libruntime::stress --silent &> /dev/null &'

#--testCase libapp::sanity \
#--testCase libapp::stress \
#--testCase childfun::fun \

# --testCase libds::dataSetStress \


# --testCase libdemystify::demystifyTest \


####################################
# --testCase libdatasourceptr::stress \  == Bug 6275 (not a valid test)
