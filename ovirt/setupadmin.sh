#!/bin/bash

# set up admin account
echo 'setup admin acct'
ADMIN_USERNAME=${ADMIN_USERNAME:-xdpadmin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-Welcome1}
ADMIN_EMAIL=${ADMIN_EMAIL:-support@xcalar.com}
XCE_HOME=/var/opt/xcalar
mkdir -p $XCE_HOME/config
chown -R xcalar:xcalar $XCE_HOME/config
jsonData="{ \"defaultAdminEnabled\": true, \"username\": \"$ADMIN_USERNAME\", \"email\": \"$ADMIN_EMAIL\", \"password\": \"$ADMIN_PASSWORD\" }"
curl -H "Content-Type: application/json" -X POST -d "$jsonData" "http://127.0.0.1:12124/login/defaultAdmin/set"

#mkdir -p /var/opt/xcalar/config
#echo '{"username":"admin","password":"6d51d4b15ded3bc357f6f1547de49cc81579e6a3b1ec85bbf50dcca20618d1c4","email":"support@xcalar.com","defaultAdminEnabled":"true"}' > /var/opt/xcalar/config/defaultAdmin.json
#chmod 0600 /var/opt/xcalar/config/defaultAdmin.json
# ted had to do this, too
#chown -R xcalar:xcalar /var/opt/xcalar/config


