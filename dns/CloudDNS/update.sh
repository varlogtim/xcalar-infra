#!/bin/bash
ZONE="${1:-xcalar-new-com}"
NOW="$(date +'%Y%m%d')"
gcloud dns --project=angular-expanse-99923 record-sets export ${ZONE}-${NOW}.zone --zone=${ZONE} --zone-file-format

echo gcloud dns --project=angular-expanse-99923 record-sets import ${ZONE}.zone --zone=${ZONE} --zone-file-format --delete-all-existing
