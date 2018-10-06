#!/bin/bash
# Wrapper around Ovirt Tool
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
OVIRT_WRAPPER="$SCRIPTDIR/../bin/ovirttool"

# if help requested, display and exit (else will have to enter credentials just for help)
if [[ $@ == *"--help"* ]]; then
  "$OVIRT_WRAPPER" --help | sed -e 's/ovirttool.py/ovirttool.sh/g' >&2
  exit 0
fi

# cmd args to send to ovirttool.py
cmds="$@"

# if they didn't pass the --user arg,
# prompt for it and add as cmd to pass
echo >&2
if [[ $@ != *"--user="* ]]; then
  read -p 'Your Xcalar LDAP username: ' uname
  cmds="$cmds --user=$uname"
fi
# prompt for password if no env variable
# (this way can set it when running unit tests)
password=${OVIRT_PASSWORD}
if [ -z $password ]; then
  read -sp 'Your Xcalar LDAP Password: ' password
  echo >&2
  echo >&2
  export OVIRT_PASSWORD=$password
fi

# will redirect stdout to a logfile
# log dir is TMPDIR env var so user can direct logs where they want
export TMPDIR="${TMPDIR:-/tmp/ovirttool/$USER/$$}"
mkdir -p $TMPDIR >&2
OVIRTLOGFILE=$TMPDIR/logfile.txt

cat << EOF >&2
Calling ovirttool!  You can track full debug log here: $OVIRTLOGFILE
EOF

# python script prepends DEBUG to every debug log statement; filter all but that
# If you're not getting any console output, check if python script has changed
# what's being prepended
"$OVIRT_WRAPPER" $cmds | tee $OVIRTLOGFILE | grep -v DEBUG
rc=${PIPESTATUS[0]}
if [ $rc != 0 ]; then
cat << EOF >&2
Encountered a problem when executing the Ovirt tool.  Exit code $rc .
Please contact jolsen@xcalar.com and provide the log at $OVIRTLOGFILE
EOF
fi
exit $rc
