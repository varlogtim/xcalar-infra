#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export XLRINFRADIR="$(cd $DIR/.. && pwd)"
export PATH=$XLRINFRADIR/bin:/opt/xcalar/bin:$PATH

if [ -d "$INSTALLER" ]; then
    echo "INSTALLER=$INSTALLER is a directory. Looking for an installer."
    INSTALLER=$(find $INSTALLER/ -type f -name 'xcalar-*-installer' | grep prod | head -1)
fi

if ! [ -r "$INSTALLER" ]; then
    echo >&2 "ERROR: Unable to find installer INSTALLER=$INSTALLER"
    exit 1
fi

test -e .venv || virtualenv .venv
source .venv/bin/activate
pip install -q -r requirements.txt

. infra-sh-lib
. azure-sh-lib
. aws-sh-lib

cd packer
export INSTALLER_URL=$(installer-url.sh -d s3 $INSTALLER)
cfn-flip <$PACKERCONFIG >packer.json

bash build.sh -only=${BUILDER} -color=false packer.json 2>&1 | tee $WORKSPACE/output.txt
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
#--> amazon-ebs-amzn1: AMIs were created:
#us-east-1: ami-0be51e55e6e7c04ca
#us-west-2: ami-0ebc8804d67bb22bd

set +e
grep -A5 "${BUILDER}: AMIs were created:" output.txt | grep "ami-" | tee amis.yml
AMI_US_EAST_1=$(awk '/us-east-1: /{print $2}' amis.yml)
AMI_US_WEST_2=$(awk '/us-west-2: /{print $2}' amis.yml)

cat >amis.properties <<EOF
ami_us_east_1=${AMI_US_EAST_1}
ami_us_west_2=${AMI_US_WEST_2}
EOF
#!/bin/bash

set -ex

SCRIPTDIR=$(cd $(dirname ${BASH_SOURCE[0]})/.. && pwd)

export XLRINFRADIR=$PWD
export PATH=$XLRINFRADIR/bin:$PATH

test -e .venv || virtualenv .venv
source .venv/bin/activate
pip install -q -r requirements.txt

. infra-sh-lib
. azure-sh-lib
. aws-sh-lib

cd $XLRINFRADIR/packer
export INSTALLER_URL=$(installer-url.sh -d s3 $INSTALLER)
cfn-flip <$PACKERCONFIG >packer.json

bash build.sh -only=${BUILDER} -color=false packer.json 2>&1 | tee $WORKSPACE/output.txt
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
#--> amazon-ebs-amzn1: AMIs were created:
#us-east-1: ami-0be51e55e6e7c04ca
#us-west-2: ami-0ebc8804d67bb22bd

set +e
grep -A5 "${BUILDER}: AMIs were created:" output.txt | grep "ami-" | tee amis.yml
AMI_US_EAST_1=$(awk '/us-east-1: /{print $2}' amis.yml)
AMI_US_WEST_2=$(awk '/us-west-2: /{print $2}' amis.yml)

cat >amis.properties <<EOF
AMI_US_EAST_1=${AMI_US_EAST_1}
AMI_US_WEST_2=${AMI_US_WEST_2}
EOF
