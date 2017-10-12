XCE_CONFIG=${XCE_CONFIG:-/etc/xcalar/default.cfg}
XCE_HOME=${XCE_HOME:-/var/opt/xcalar}
XLRDIR=${XLRDIR:-/opt/xcalar}
XCE_LICENSEDIR=${XCE_LICENSEDIR:-/etc/xcalar}
ADMIN_USERNAME=${ADMIN_USERNAME:-"xcuser"}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-"Xc4larStanf0rd"}
ADMIN_EMAIL=${ADMIN_EMAIL:-"xcuser@xcalar.com"}
XCALAR_ADVENTURE_DATASET=${XCALAR_ADVENTURE_DATASET:-"http://pub.xcalar.net/datasets/xcalarAdventure.tar.gz"}

LICENSE="AEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJAAAJAAAAACAVZHBAJXAXN7SB5D3Y45B7BJSHE62ST8S7N7QWHYP9XQE6AP67552FAS3Y8FXPAE6CXVXGWMDY4YTST2AABWAQ========"
#License key version is: Version 1.0.2
#Product family is: XcalarX
#Product is: Xce
#Product version is: 1.2.2.0
#Product platform is: Linux x86-64
#License expiration is: 10/19/2017
#Node count is: 1
#User count is: 16

safe_curl () {
    curl -4 --location --retry 20 --retry-delay 3 --retry-max-time 60 "$@"
}

postConfig() {
    sudo cp "$XCE_CONFIG" "${XCE_CONFIG}.bak"

    # Turn on support bundles
    echo "Constants.SendSupportBundle=true" | sudo tee -a "$XCE_CONFIG"

    # Add in Azure Blob Storage SAS tokens
    echo "AzBlob.stanfordstudentsdatasets.sasToken=?sv=2017-04-17&ss=b&srt=sco&sp=rwlac&se=2017-10-14T22:55:26Z&st=2017-10-12T14:55:26Z&spr=https&sig=7KpOaXGXX3sID3b1bhPrlIF7m0ALQsuPW9A4PkQ5rm0%3D" | sudo tee -a "$XCE_CONFIG"
    echo "AzBlob.xcalardatawarehouse.sasToken=?sv=2017-04-17&ss=b&srt=sco&sp=rl&se=2017-10-14T23:55:11Z&st=2017-10-12T15:55:11Z&spr=https&sig=%2BKMdhtUbBKrDicTGVAAPzkCXk6azD3DgHAoGbhdN7MQ%3D" | sudo tee -a "$XCE_CONFIG"

    # Burn the trial license
    LICENSE_FILE="$XCE_LICENSEDIR/XcalarLic.key"
    sudo cp "$LICENSE_FILE" "${LICENSE_FILE}.bak"
    echo "$LICENSE" | sudo tee "$LICENSE_FILE"

    # Add default admin user
    jsonData="{ \"defaultAdminEnabled\": true, \"username\": \"$ADMIN_USERNAME\", \"email\": \"$ADMIN_EMAIL\", \"password\": \"$ADMIN_PASSWORD\" }"
    sudo mkdir -p "$XCE_HOME/config"
    sudo chown -R xcalar:xcalar "$XCE_HOME/config"
    echo "Creating default admin user $ADMIN_USERNAME ($ADMIN_EMAIL)"
    # Don't fail the deploy if this curl doesn't work
    safe_curl -H "Content-Type: application/json" -X POST -d "$jsonData" "http://127.0.0.1:12124/login/defaultAdmin/set" || true

    # Let's retrieve the xcalar adventure datasets now
    if [ ! -d "/netstore" ]; then
        sudo mkdir -p /netstore/datasets/adventure
        safe_curl -sSL "$XCALAR_ADVENTURE_DATASET" > xcalarAdventure.tar.gz
        tar -zxvf xcalarAdventure.tar.gz
        sudo mv XcalarTraining /netstore/datasets/ || true
        sudo mv dataPrep /netstore/datasets/adventure/ || true
        sudo chown -R xcalar:xcalar /netstore
    fi

    sudo service xcalar stop
    sudo service xcalar start
}

postConfig
