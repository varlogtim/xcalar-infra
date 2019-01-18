#!/bin/bash

set +e

VAULT=${VAULT:-$(command -v vault)}
export VAULT_ADDR="${VAULT_ADDR:-https://vault.service.consul:8200}"
PUPPET_CONF=/etc/puppetlabs/puppet/puppet.conf
if ! certname=$(awk '/^certname/{print $(NF)}' $PUPPET_CONF) && [ -n "$certname" ]; then
    certname=$(hostname -f)
fi
CERT=/etc/puppetlabs/puppet/ssl/certs/${certname}.pem
KEY=/etc/puppetlabs/puppet/ssl/private_keys/${certname}.pem

vault_renew() {
    sudo VAULT_TOKEN=$VAULT_TOKEN $VAULT token renew \
        -address $VAULT_ADDR -client-cert $CERT -client-key $KEY -client-key 2>&1
}

if [ -z "$VAULT_TOKEN" ]; then
    if [ -e ~/.vault-token ]; then
        export VAULT_TOKEN=$(cat ~/.vault-token)
    fi
fi

if [ -n "$VAULT_TOKEN" ]; then
    if ! SELF=$($VAULT read -field=data -format=json -field=data auth/token/lookup-self); then
        unset VAULT_TOKEN
        rm -f ~/.vault-token
    else
        if [[ $(jq -r .renewable <<< $SELF) == true ]]; then
            if [[ $(jq -r .ttl <<< $SELF) -gt 1800 ]]; then
                exit 0
            fi
            if vault_renew; then
                echo >&2 "INFO: Renewed your vault token"
                exit 0
            fi
            unset VAULT_TOKEN
            rm -f ~/.vault-token
            echo >&2 "WARN: Renewing your token didn't work"
        fi
    fi
fi

if [ -n "$VAULT_TOKEN" ]; then
    exit 0
fi

if VAULT_TOKEN=$(sudo $VAULT login -token-only -method=cert -path=cert -address=$VAULT_ADDR \
    -client-cert $CERT -client-key $KEY); then
        echo "$VAULT_TOKEN" > ~/.vault-token
        echo >&2 "INFO: Renewed your vault token"
        exit 0
fi
echo >&2 "ERROR: Authenticating with Vault"
exit 1
