#!/bin/bash

DOMAIN="${1?Specify domain}"

test -e ${DOMAIN}.html || curl -i -fL -H "Accept: application/json" 'https://crt.sh/?q=%25.'${DOMAIN} -o ${DOMAIN}.html
grep ${DOMAIN} ${DOMAIN}.html | grep TD | sed -e 's/    <TD>//g; s,</TD>,,g' | grep -v '<TD ' | sort | uniq
