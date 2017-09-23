#!/bin/bash
# This is a sample Jenkins script that utilizes the end-to-end test framework.
# Sample Jenkins params:
#     - BACK_GIT_BRANCH: master
#     - GIT_REPOSITORY: ssh://gerrit.int.xcalar.com:29418/xcalar/xcalar-infra.git
#     - NODE: 10.10.4.110
#     - NUM_USERS: 1
#     - MODE: ten
#     - SSHUSER: root
ps -ef | grep "server.p[y]" | awk '{print $2}' | xargs kill -9 || true
_ssh () {
    ssh -t -T -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}

XCALAR_ROOT=$(_ssh $SSHUSER@$NODE "grep -o 'Constants.XcalarRootCompletePath=[^,]*' /etc/xcalar/default.cfg | cut -d '=' -f 2")
XCCLI=$(_ssh $SSHUSER@$NODE "echo \${XLRDIR:-/opt/xcalar}/bin/xccli")
LATEST_INSTALLER=`ls /netstore/builds/byJob/BuildTrunk/$INSTALLERNUMBER/debug/*$INSTALLERNUMBER*-installer`
if [ -e "$LATEST_INSTALLER" ]; then
    echo "Using BuildTrunk Debug build number $INSTALLERNUMBER"
else
    echo "Using BuildTrunk latest Debug build"
    LATEST_INSTALLER="/netstore/builds/byJob/BuildTrunk/xcalar-latest-installer-debug"
fi

echo "Installer location: $LATEST_INSTALLER"

echo "Building $GUI_PRODUCT"
export XLRDIR=`pwd` #Not used
export XLRGUIDIR=`pwd` #Not used
make installer product=$GUI_PRODUCT

if [ "$GUI_PRODUCT" = "XI" ]; then
    GUI_FOLDER=xcalar-insight
    echo "Tarring up xcalar-insight"
    tar -zcvf xcalar-gui.tar.gz xcalar-insight
else
    GUI_FOLDER=xcalar-design
    echo "Tarring up xcalar-design"
    tar -zcvf xcalar-gui.tar.gz xcalar-design
fi

#NUM_USERS=$(shuf -i 2-3 -n 1)
NUM_USERS=2

echo "Installing required packages"
if ! grep -q Ubuntu /etc/os-release; then
  echo "This only works on ubuntu"
  exit 1
fi
sudo apt-get install -y libnss3-dev chromium-browser

if [ ! -f /usr/bin/chromedriver ]; then
    echo "Wget chrome driver"
    wget http://chromedriver.storage.googleapis.com/2.24/chromedriver_linux64.zip
    unzip chromedriver_linux64.zip
    chmod +x chromedriver
    sudo mv chromedriver /usr/bin/
else
    pwd
    echo "Chrome driver already installed"
fi

sudo apt-get install -y libxss1 libappindicator1 libindicator7
sudo apt-get install -y python-pip
sudo pip install pyvirtualdisplay selenium
sudo apt-get install -y Xvfb

echo "Stop usrnode remotely"
_ssh $SSHUSER@$NODE "/opt/xcalar/bin/xcalarctl stop-supervisor" < /dev/null || true
echo "Cleaning buffer cache file"
_ssh $SSHUSER@$NODE "rm -rf /dev/shm/*" < /dev/null || true
echo "Cleaning XLRROOT"
_ssh $SSHUSER@$NODE "rm -rf $XCALAR_ROOT/*" < /dev/null || true
echo "Installing perpetual license"
_ssh $SSHUSER@$NODE "cp /netstore/users/jerene/XcalarLic.key /etc/xcalar"
echo "Installing latest build"
_ssh $SSHUSER@$NODE "$LATEST_INSTALLER --stop --start"

echo "Installing UI in this build"
scp xcalar-gui.tar.gz jenkins@$NODE:/var/www
_ssh $SSHUSER@$NODE "cd /var/www; tar -zxvf xcalar-gui.tar.gz; rm -rf xcalar-gui; mv $GUI_FOLDER xcalar-gui"
date
timeOut=50
counter=0
set +e
while true; do

    _ssh $SSHUSER@$NODE "$XCCLI -c \"version\"" | grep "Backend Version"

    if [ $? -eq 0 ]; then
        break
    fi
    sleep 5s
    counter=$(($counter + 5))
    if [ $counter -gt $timeOut ]; then
        echo "usrnode time out"
        exit 1
    fi
done

echo "Starting test driver"
python assets/test/testSuitePython/server.py -t $NODE 2>&1 </dev/null &
sleep 5

TEST_DRIVER_HOST=$(hostname)
TEST_DRIVER_PORT="5909"

echo "Running test suites in pseudo terminal"
URL="http://$TEST_DRIVER_HOST:$TEST_DRIVER_PORT/action?name=start&mode=$MODE&timeDilation=3&host=$NODE&server=$TEST_DRIVER_HOST&port=$TEST_DRIVER_PORT&users=$NUM_USERS"
HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X GET $URL)

URL="http://$TEST_DRIVER_HOST:$TEST_DRIVER_PORT/action?name=getstatus"
HTTP_BODY="Still running"
while [ "$HTTP_BODY" == "Still running" ]
do
    echo "Test suite is still running"
    sleep 5
    # store the whole response with the status at the and
    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X GET $URL)
    # extract the body
    HTTP_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
done
echo "Test suite finishes"
echo "$HTTP_BODY"
echo "Closing test driver"
URL="http://$TEST_DRIVER_HOST:$TEST_DRIVER_PORT/action?name=close"
HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X GET $URL)
if [[ "$HTTP_BODY" == *"status:fail"* ]]; then
  echo "TEST SUITE FAILED"
  exit 1
else
  echo "TEST SUITE PASS"
  exit 0
fi


