# CloudDNS

Some of our domains are registered with Google Domains (domains.google.com) and hosted on CloudDNS
in our [GCP account][1]

## Overview

The process of renewing LetsEncrypt (LE) certs is the same as anywhere else. We need to prove ownership
of the domainname(s) in question, either by hosting a special file on the target webserver or by setting
a DNS TXT record. We can't easily make all the various domains serve a special file for us, but we can
set values in DNS. We use the `dns-01` challange.


## letsencrypt.sh

For this to work we need to have credentials and API access to our DNS zone provider, Google CloudDNS
in this case. We create a service principal and save the JSON credentials securely. The env-var
`GCE_SERVICE_ACCOUNT_FILE` is used to indicate the location. `GCE_PROJECT` can also be set, and defaults
to angular-expanse-99923. `GCE_DOMAIN` is set to xcalar.com. All of the above can be overriden with
those same envvars before running the `letsencrypt.sh` script. Underneath the covers, the script run
`lego` to automate the request/reply back and forth to LE to set the challanges.

The main argument you need is `-d <domain>` for individual domains, or `-d domain.txt` to load a file
containing domain names. We use the latter.

Try a dry-run first to ensure your environment is ready

    ./letsencrypt.sh -d test.xcalar.com --dry-run

    ./letsencrypt.sh -d domains.txt

## Output

The certificate will be in `$XLRINFRA/dns/lego/certificates/firstdomain.domain.crt` and .key files are
needed.

To view all the names that a certificate can be used for, use:

    openssl x509 -noout -text -in www.xcalar.com.crt

One certificate can (and does) name multiple domains. We do this to overcome LE request/certificate
limits.

## Registering new certificates with GoDaddy

Log in to [GoDaddy][2], select the cPanel UI,

- Select the SSL Manager, select Private Key and upload the new private .key file
- Go back to the SSL Manager, select Certificates and upload the new .crt file
- Go back to the SSL Manager, select "Install and Manage SSL.."

Repeat the following for each domain/subdomain:

- Scroll down to "Install an SSL Website"
- In the dropdown select one of the domains for which your certificate is valid for
- Once selected press "Auto-fill", it should pick up your new cert
- Scroll down and press Save



### Links

[1]: https://console.cloud.google.com/net-services/dns/zones?project=angular-expanse-99923
[2]: https://sso.godaddy.com/login


