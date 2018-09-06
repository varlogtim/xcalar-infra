#!/bin/bash
#
if [ -z "$CERTNAME" ]; then
    if ! CERTNAME=$(awk '/^certname/{print $(NF)}' /etc/puppetlabs/puppet/puppet.conf) || [ -z "$CERTNAME" ]; then
        CERTNAME="$(hostname -f)"
    fi
fi
export VAULT_ADDR="${VAULT_ADDR:-https://vault:8200}"
VAULT=$(command -v vault)
CERT=/etc/puppetlabs/puppet/ssl/certs/${CERTNAME}.pem
KEY=/etc/puppetlabs/puppet/ssl/private_keys/${CERTNAME}.pem

if [ -n "$VAULT_TOKEN" ]; then
    if /usr/bin/sudo VAULT_TOKEN=${VAULT_TOKEN} ${VAULT} token renew -address=${VAULT_ADDR} -client-cert=${CERT} -client-key=${KEY} -format=json | jq -r '.auth.client_token'; then
        exit 0
    fi
fi

if [ $# -eq 0 ]; then
    set -- -token-only
fi

/usr/bin/sudo -H ${VAULT} login -address=${VAULT_ADDR} -method=cert -client-cert=${CERT} -client-key=${KEY} "$@"

if test -r $KEY; then
    vault login -method=cert -client-cert=${CERT} -client-key=${KEY} "$@"
else
    eval /usr/bin/sudo -H ${VAULT} login -address=${VAULT_ADDR} -method=cert -client-cert=${CERT} -client-key=${KEY} "$@"
fi
