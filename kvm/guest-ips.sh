#!/bin/bash
#
# List all ip addresses for all domains
#

# get all domain ids
for dom in $(virsh list | tail -n+3 | awk '{print $1}' | sed -e '/^$/d'); do
    # get all mac addresses for each domain
    for mac in $(virsh domiflist $dom | grep -o -E "([0-9a-f]{2}:){5}([0-9a-f]{2})"); do
        # look at the arp table for the mac address
        arp -e | grep $mac | grep -o -P "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    done
done
