#!/bin/bash
#
# Deploy a Xcalar cluster on Azure

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

INSTALLER="${INSTALLER:-/netstore/qa/Downloads/byJob/BuildTrunk/xcalar-latest-installer-prod}"
INSTALLER_URL=""
COUNT=1
INSTANCE_TYPE="Standard_E8s_v3"
CLUSTER="`id -un`-xcalar"
LOCATION="westus2"
TEMPLATE="$XLRINFRADIR/azure/xdp-standard/devTemplate.json"
LICENSE=""

BUCKET="${BUCKET:-xcrepo}"
CUSTOM_SCRIPT_NAME="devBootstrap.sh"

BOOTSTRAP="${BOOTSTRAP:-$XLRINFRADIR/azure/bootstrap/$CUSTOM_SCRIPT_NAME}"
BOOTSTRAP_SHA=`sha1sum "$BOOTSTRAP" | awk '{print $1}'`
S3_BOOTSTRAP_KEY="bysha1/$BOOTSTRAP_SHA/`basename $BOOTSTRAP`"
S3_BOOTSTRAP="s3://$BUCKET/$S3_BOOTSTRAP_KEY"
PARAMETERS_DEFAULTS="${PARAMETERS_DEFAULTS:-$XLRINFRADIR/azure/xdp-standard/parameters.json.defaults}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://s3-us-west-2.amazonaws.com/$BUCKET/$S3_BOOTSTRAP_KEY}"

usage () {
    cat << EOF
    usage: $0 [-i installer (default: $INSTALLER)] [-t instance-type (default: $INSTANCE_TYPE)] [-c count (default: $COUNT)] [-n clusterName (default: $CLUSTER)] [-l location (default: $LOCATION)] [-k licenseKey]

EOF
    exit 1
}

while getopts "hi:c:t:n:l:k:" opt "$@"; do
    case "$opt" in
        h) usage;;
        i) INSTALLER="$OPTARG";;
        c) COUNT="$OPTARG";;
        t) INSTANCE_TYPE="$OPTARG";;
        n) CLUSTER="$OPTARG";;
        l) LOCATION="$OPTARG";;
        k) LICENSE="$OPTARG";;
        --) break;;
        *) echo >&2 "Unknown option $opt"; usage;;
    esac
done

# Check if S3_BOOTSTRAP exists
aws s3 cp "$S3_BOOTSTRAP" - >/dev/null 2>&1
ret=$?
if [ "$ret" != "0" ]; then
    echo "$S3_BOOTSTRAP does not exists. Uploading $BOOTSTRAP"
    aws s3 cp "$BOOTSTRAP" "$S3_BOOTSTRAP"
    aws s3api put-object-acl --acl public-read --bucket "$BUCKET" --key "$S3_BOOTSTRAP_KEY"
fi

if ! test "`az group exists --name "$CLUSTER" --output tsv`" = true; then 
    az group create --name "$CLUSTER" --location "$LOCATION"; 
fi

if [ -z "$INSTALLER_URL" ]; then
    if [ "$INSTALLER" = "none" ]; then
        INSTALLER_URL="http://none"
    elif [[ "$INSTALLER" =~ ^s3:// ]]; then
        if ! INSTALLER_URL="$(aws s3 presign "$INSTALLER")"; then
            echo >&2 "Unable to sign the s3 uri: $INSTALLER"
        fi
    elif [[ "$INSTALLER" =~ ^gs:// ]]; then
        INSTALLER_URL="http://${INSTALLER#gs://}"
    elif [[ "$INSTALLER" =~ ^http[s]?:// ]]; then
        INSTALLER_URL="$INSTALLER"
    else
        if ! INSTALLER_URL="$($XLRINFRADIR/bin/installer-url.sh -d s3 "$INSTALLER")"; then
            echo >&2 "Failed to upload or generate a url for $INSTALLER"
            exit 1
        fi
    fi
fi

DEPLOY="$CLUSTER-deploy"
EMAIL="`id -un`@xcalar.com"
az group deployment create --resource-group "$CLUSTER" --name "$DEPLOY" --template-file "$TEMPLATE" --parameters "`jq -r '.parameters + { domainNameLabel: {value:"'$CLUSTER'"},\
                                      customScriptName: {value:"'$CUSTOM_SCRIPT_NAME'"},\
                                      installerUrl: {value:"'$INSTALLER_URL'"},\
                                      bootstrapUrl: {value:"'$BOOTSTRAP_URL'"},\
                                      licenseKey: {value:"'$LICENSE'"},\
                                      adminEmail: {value:"'$EMAIL'"},\
                                      scaleNumber: {value:'$COUNT'},\
                                      appName: {value:"'$CLUSTER'"},\
                                      appUsername: {value:"admin"},\
                                      appPassword: {value:"Welcome1"},\
                                      vmSize: {value:"'$INSTANCE_TYPE'"}
                                    }|tojson' $PARAMETERS_DEFAULTS`"
$XLRINFRADIR/azure/azure-cluster-info.sh "$CLUSTER"
