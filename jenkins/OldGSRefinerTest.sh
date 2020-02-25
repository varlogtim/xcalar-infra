#!/bin/bash
set -e
set -x

say () {
    echo >&2 "$*"
}

say "OldGSRefinerTest START ===="

if [ -z $HOST ]; then
    say "ERROR: HOST cannot be empty"
    exit 1
fi
if [ -z $PORT ]; then
    say "ERROR: PORT cannot be empty"
    exit 1
fi
if [ -z $USER ]; then
    say "ERROR: USER cannot be empty"
    exit 1
fi
if [ -z $PASSWORD ]; then
    say "ERROR: PASSWORD cannot be empty"
    exit 1
fi
if [ -z $BATCHES ]; then
    say "ERROR: BATCHES cannot be empty"
    exit 1
fi
if [ -z $INSTANCES ]; then
    say "ERROR: INSTANCES cannot be empty"
    exit 1
fi


say "OldGSRefinerTest BUILD ===="
cd $XLRDIR
#cmBuild clean
#cmBuild config debug
# XXXrs - Tech Debt
# Only want to get the python in place to run our Python script,
# but can't # figure out the right make target in a timely manner.
# "xce" is (very) heavyweight but works reliably, so just use it (forever?).
#cmBuild xce
python3 -m pip install -U pip
curl https://storage.googleapis.com/repo.xcalar.net/xcalar-sdk/requirements-2.2.0.txt --output requirements.txt
pip install -r requirements.txt

say "OldGSRefinerTest RUN old_gs_refiner_test.py ===="

host_options="--host $HOST --port $PORT"
user_options="--user $USER --pass $PASSWORD"
load_options="--batches $BATCHES --instances $INSTANCES"
stats_options="--statsfreq $STATSFREQ"


XLRINFRADIR="${XLRINFRADIR:-${XLRDIR}/xcalar-infra}"
cd ${XLRINFRADIR}/jenkins/scripts
python ./old_gs_refiner_test.py $host_options $user_options $load_options $stats_options

say "OldGSRefinerTest END ===="
