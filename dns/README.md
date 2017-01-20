# Xcalar Infrastructure DNS Management


## Google CloudDNS

Exporting your zone from Google CloudDNS:

    $ ZONE=xcalar-com  # The CloudDNS zone name. Not same as the domain name.
    $ gcloud dns record-sets export "CloudDNS/${ZONE}.zone" --zone-file-format -z "${ZONE}"


Importing your zone into CloudDNS:

    $ gcloud dns record-sets import "CloudDNS/${ZONE}.zone" --zone-file-format -z "${ZONE}"

To force overwriting any existing records add the `--delete-all-existing` flag.

## GoDaddy

We imported the GoDaddy zone file for xcalar.com by removing the SOA and NS records. The original
can be found in `GoDaddy/xcalar.com.zone` and the modified one is in `CloudDNS/xcalar.com.zone`


## Comparing records in two providers

Use the dns_diff.sh tool to compare records on two DNS servers

    $ ./dns_diff.sh xcalar.com ns52.domaincontrol.com ns-cloud-c1.googledomains.com
