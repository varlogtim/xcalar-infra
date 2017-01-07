#!/bin/bash

echo "Starting test driver"
# TODO: need to read TARGET_HOST from Jenkins input params
TARGET_HOST="10.10.4.134"
python server.py -t $TARGET_HOST -v 2>&1 &
sleep 1

TEST_DRIVER_HOST="euler"
TEST_DRIVER_PORT="5909"

echo "Running test suites in pseudo terminal"
# URL="http://$TEST_DRIVER_HOST:$TEST_DRIVER_PORT/start/1"
URL="http://$TEST_DRIVER_HOST:$TEST_DRIVER_PORT/action?name=start&mode=ten&host=$TARGET_HOST&server=$TEST_DRIVER_HOST&port=$TEST_DRIVER_PORT&users=2"
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
if [[ "$HTTP_BODY" == *"status:pass"* ]]; then
  echo "TEST SUITE PASS"
else
  echo "TEST SUITE FAILED"
fi
echo "Cleaning export folder in target host"
#chmod 777 -R /var/opt/xcalar/export/
#rm -rf /var/opt/xcalar/export/*
if [[ "$HTTP_BODY" == *"status:pass"* ]]; then
  exit 0
else
  exit 1
fi

