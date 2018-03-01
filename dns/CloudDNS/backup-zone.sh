#!/bin/bash
set -e

ZONE="${1:-xcalar-com}"
NOW="$(date +'%Y%m%d')"
ZONE="${ZONE//\./-}"     # replace periods with dashes
export GCE_PROJECT=${GCE_PROJECT:-angular-expanse-99923}

gcloud dns --project=${GCE_PROJECT} record-sets export ${ZONE}-${NOW}.zone --zone=${ZONE} --zone-file-format
if [ -e "${ZONE}.zone" ]; then
    echo >&2 "Saving old ${ZONE}.zone to ${ZONE}.zone.bak"
    mv -v "${ZONE}.zone" "${ZONE}.zone.bak"
fi

mv ${ZONE}-${NOW}.zone ${ZONE}.zone

echo >&2 ""
echo >&2 "To import the zone back into Google DNS:"
echo >&2 "gcloud dns --project=${GCE_PROJECT} record-sets import ${ZONE}.zone --zone=${ZONE} --zone-file-format --delete-all-existing"

