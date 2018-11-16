#!/bin/bash
# Wrapper around Ovirt Tool

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
OVIRT_WRAPPER="$SCRIPTDIR/../bin/ovirttool"

# allow uname/pword as env vars for automation
UNAME="${OVIRT_UNAME:-""}"
PASSWORD="${OVIRT_PASSWORD:-""}"

# if help requested, display and exit (else will have to enter credentials just for help)
if [[ $@ == *"--help"* ]]; then
  "$OVIRT_WRAPPER" --help | sed -e 's/ovirttool.py/ovirttool.sh/g' >&2
  exit 0
fi

# cmd args to send to ovirttool.py
cmds="$@"

# tool can accept both env var and --user arg for username;
# --user will take precedence if both supplied
if [[ $@ != *"--user="* ]] && [ -z "$UNAME" ]; then
  echo >&2
  read -p 'Your Xcalar LDAP username: ' UNAME
fi
export OVIRT_UNAME="$UNAME"
if [ -z "$PASSWORD" ]; then
  read -sp 'Your Xcalar LDAP Password: ' PASSWORD
  echo >&2
  echo >&2
fi
export OVIRT_PASSWORD="$PASSWORD"

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
