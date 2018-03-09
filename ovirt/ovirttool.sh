#!/bin/bash
# Wrapper around Ovirt Tool

# if they wanted help display that
if [[ $@ == *"--help"* ]]; then
  python3 ovirttool.py --help | sed -e 's/ovirttool.py/ovirttool.sh/g' >&2
  exit 0
fi

# check if required modules installed on their machine
python3 -c "import ovirtsdk4" >&2
rc=$?
if [ $rc != 0 ]; then
  echo >&2
  echo "Please install the ovirtsdk4 module before running this tool." >&2
  echo "To install: pip3 install --user ovirt-engine-sdk-python" >&2
  echo >&2
  exit $rc
fi
python3 -c "import paramiko" >&2
rc=$?
if [ $rc != 0 ]; then
  echo >&2
  echo "You must install paramiko module before running this tool." >&2
  echo "To install: pip3 install --user paramiko" >&2
  echo >&2
  exit $rc
fi
python3 -c "import requests" >&2
rc=$?
if [ $rc != 0 ]; then
  echo >&2
  echo "You must install requests module before running this tool." >&2
  echo "To install: pip3 install --user requests" >&2
  echo >&2
  exit $rc
fi

# if they didn't pass the --user arg, prompt for it
echo >&2
if [[ $@ != *"--user="* ]]; then
  read -p 'Username: ' uname
fi
# always prompt for password
read -sp 'Password: ' password
echo >&2
echo >&2
export OVIRT_PASSWORD=$password

# will redirect stdout and stderr to a logfile
# log dir is TMPDIR env var so user can direct logs where they want
# else use our def value
# export so we can access in the python script
export TMPDIR="${TMPDIR:-/tmp/ovirttool/$USER/$$}"
mkdir -p $TMPDIR >&2
export OVIRTLOGFILE=$TMPDIR/logfile.txt

echo "Calling ovirttool!  This process could take up to 45 minutes, depending on xcalar installation and cluster size." >&2
echo "A summary displaying info about your provisioned VMs/cluster will be displayed upon successful completion." >&2
echo "You can track progress here: $OVIRTLOGFILE"
echo >&2

cmds="--user=$uname $@"
python3 ovirttool.py $cmds > $OVIRTLOGFILE 2>&1
#python3 ovirttool.py $cmds 2> $OVIRTLOGFILE 1> out.txt
rc=$?
if [ $rc != 0 ]; then
  cat $OVIRTLOGFILE >&2
  echo >&2
  echo "Encountered a problem when executing the Ovirt tool.  See the error above! Exit code $rc . " >&2
  echo "Please contact jolsen@xcalar.com and provide the log at $OVIRTLOGFILE" >&2
  exit $rc
else
  # display the summary for them

  echo >&2
  echo "Your job has completed.  The full log is available here $OVIRTLOGFILE" >&2
  echo >&2
  awk '/SUMMARY END/{show=0} show; /SUMMARY START/ { show=1 }' $OVIRTLOGFILE >&2

fi

