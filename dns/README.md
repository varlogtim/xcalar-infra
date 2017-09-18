# Xcalar Infrastructure DNS Management


## Google CloudDNS

Exporting your zone from Google CloudDNS:

    $ ZONE=xcalar-com  # The CloudDNS zone name. Not same as the domain name.
    $ gcloud dns record-sets export "CloudDNS/${ZONE}.zone" --zone-file-format -z "${ZONE}"


Importing your zone into CloudDNS:

    $ gcloud dns record-sets import "CloudDNS/${ZONE}.zone" --zone-file-format -z "${ZONE}"

To force overwriting any existing records add the `--delete-all-existing` flag.

## Comparing records in two providers

Use the dns_diff.sh tool to compare records on two DNS servers

    $ ./dns_diff.sh xcalar.com ns52.domaincontrol.com ns-cloud-c1.googledomains.com

## GoDaddy

We imported the GoDaddy zone file for xcalar.com by removing the SOA and NS records. The original
can be found in `GoDaddy/xcalar.com.zone` and the modified one is in `CloudDNS/xcalar.com.zone`

### Updating GoDaddy LE SSL certs (for www.xcalar.com, xcalar.com, etc)

You need to run the LE certbot client to use DNS-01 (dns challenge) for LE certs. First clone the
repo, then run the certbot-auto command. This will ask you to set some DNS records. Log into GoDaddy
DNS manager https://dcc.godaddy.com/manage/xcalar.com/dns and set the two (or more) TXT records:

    _acme-challenge      <longcode1>
    _acme-challenge.www  <longcode2>

Save it in GoDaddy.

Certbot instructions:

    $ git clone https://github.com/certbot/certbot
    $ ./certbot-auto  certonly -d xcalar.com -d www.xcalar.com --manual --agree-tos -m abakshi@xcalar.com --preferred-challenges dns-01
    Requesting to rerun ./certbot-auto with root privileges...
    Saving debug log to /var/log/letsencrypt/letsencrypt.log
    Plugins selected: Authenticator manual, Installer None
    Cert is due for renewal, auto-renewing...
    Renewing an existing certificate
    Performing the following challenges:
    dns-01 challenge for xcalar.com
    dns-01 challenge for www.xcalar.com
    -------------------------------------------------------------------------------
    NOTE: The IP of this machine will be publicly logged as having requested this
    certificate. If you're running certbot in manual mode on a machine that is not
    your server, please ensure you're okay with that.
    Are you OK with your IP being logged?
    -------------------------------------------------------------------------------
    (Y)es/(N)o: Y
    -------------------------------------------------------------------------------
    Please deploy a DNS TXT record under the name
    _acme-challenge.xcalar.com with the following value:
    PXVTGhI63zFdPrPg74BiEukh1Y5OHOvIzxWXhOhF9q4
    Before continuing, verify the record is deployed.
    -------------------------------------------------------------------------------
    Press Enter to Continue
    -------------------------------------------------------------------------------
    Please deploy a DNS TXT record under the name
    _acme-challenge.www.xcalar.com with the following value:
    ZaYb2_hm_wFtuNUZQebvTSN9PxbCSntcEGT961a8wL8
    Before continuing, verify the record is deployed.
    -------------------------------------------------------------------------------
    Press Enter to Continue

Before continuing in certbot-auto, verify the settings have been applied. SSH
into another machine

    $ dig -t txt _acme-challenge.xcalar.com
    longcode1

    $ dig -t txt _acme-challenge.www.xcalar.com
    longcode2


Go back to the certbot-auto screen and press Enter to continue:

    Press Enter to Continue
    Waiting for verification...
    Cleaning up challenges
    IMPORTANT NOTES:
    - Congratulations! Your certificate and chain have been saved at:
    /etc/letsencrypt/live/www.xcalar.com/fullchain.pem
    Your key file has been saved at:
    /etc/letsencrypt/live/www.xcalar.com/privkey.pem
    Your cert will expire on 2017-12-17. To obtain a new or tweaked
    version of this certificate in the future, simply run certbot-auto
    again. To non-interactively renew *all* of your certificates, run
    "certbot-auto renew"
    - If you like Certbot, please consider supporting our work by:
    Donating to ISRG / Let's Encrypt:   https://letsencrypt.org/donate
    Donating to EFF:                    https://eff.org/donate-le


Now you have your cert and key file

    $ sudo cat /etc/letsencrypt/live/www.xcalar.com/cert.pem
    $ sudo cat /etc/letsencrypt/live/www.xcalar.com/privkey.pem


Log into the GoDaddy domain manager for xcalar.com, https://a2plcpnl0278.prod.iad2.secureserver.net:2083/cpsess5982241450/frontend/gl_paper_lantern/ssl/install.html,
and select 'Manage SSL Certificate'. Paste the cert.pem, privkey.pem, save and reload. Done!

