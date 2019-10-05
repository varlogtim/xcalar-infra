

ARN_XCALAR_CLOUD_ORIG = arn:aws:route53:::/hostedzone/ZZ2J6FQ00JXZX
ZONE_ID_ORIG = ZZ2J6FQ00JXZX
PROFILE_ORIG = default

ARN_XCALAR_CLOUD_NEW = arn:aws:route53:::/hostedzone/Z3OAJRCVE57A0G
ZONE_ID_NEW = Z3OAJRCVE57A0G
PROFILE_NEW = pegasus

all: $(ZONE_ID_NEW).json

# Recover from a source vault to vat.
$(ZONE_ID_NEW).json:
	aws --profile $(PROFILE_ORIG) route53 list-resource-record-sets --hosted-zone-id $(ZONE_ID_ORIG) | \
	    jq -r  '{Changes: [{Action:"CREATE", "ResourceRecordSet": .ResourceRecordSets[] }]}' > $@
	echo "Now you must modify this file and remove the NS and SOA record for the top level domain"


apply: $(ZONE_ID_NEW).json
	aws --profile $(PROFILE_NEW) route53 change-resource-record-sets --hosted-zone-id $(ZONE_ID_NEW) --change-batch "$(ZONE_ID_NEW).json"
