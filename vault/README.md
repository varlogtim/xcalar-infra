# Vault

## Using Vault to authenticate against services


Make sure `VAULT_ADDR` is set to `https://vault:8200`

Login as my user and get the token. By default it is written to ~/.vault-token

    $ vault login -token-only -method=ldap username=abakshi

    Password (will be hidden):
    The token was not stored in token helper. Set the VAULT_TOKEN environment
    variable or pass the token below with each request to Vault.

    5db0abc8-866b-ece9-413f-c0518f8848aa

Export that for ease of use (or run the above without -token-only)

    export VAULT_TOKEN=5db0abc8-866b-ece9-413f-c0518f8848aa
    echo $VAULT_TOKEN > ~/.vault-token

You're now authenticated to vault via the LDAP backend. As such you're a member
of some groups. Groups map to policies that enable you to read/write endpoints
in Vault.

One such endpoint is `aws/creds/<name>`. Reading from this endpoint generates a
temporary IAM user and you're provided with API keys to act as that user. When
the TTL is up (1h in this case), Vault will go and delete the API keys as well
as deleting the user.


    $ vault read aws/creds/deploy

    Key                Value
    ---                -----
    lease_id           aws/creds/deploy/acea9ff6-9e35-84bd-85e7-f6030b4e3fb9
    lease_duration     1h
    lease_renewable    true
    access_key         AKIAJIFWMKHJDKVH5GUA
    secret_key         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
    security_token     <nil>


A better way that doesn't involve generating a temporary IAM user, is to use STS. The idea
is the same, but you needn't go through an intermediate IAM user. There is one extra bit
of information for you to keep track of, however, the security token.

    vault write -f aws/sts/deploy

    Key                Value
    ---                -----
    lease_id           aws/sts/deploy/8c0b442f-f02a-8f13-58d3-076cfab81662
    lease_duration     59m59s
    lease_renewable    false
    access_key         ASIAIDC36I7SQP3HRKEQ
    secret_key         /chT0xMqvZshFYvtSMqmxUWyabUMldzjMGRVcnVF
    security_token     FQoDYXdzEM7//////////wEaDN2+gNym3i/X3B...[snip]

Now you can use those creds to query `aws ec2`

    export AWS_ACCESS_KEY_ID=ASIAIDC36I7SQP3HRKEQ
    export AWS_SECRET_ACCESS_KEY=/chT0xMqvZshFYvtSMqmxUWyabUMldzjMGRVcnVF
    export AWS_SESSION_TOKEN="FQoDYXdzEM7//////////wEaDCWhDx....[snip]

    $ aws ec2 describe-instances
    {
        "Reservations": []
    }

## Using Vault CA for internal certificates

Vault is configured with an intermediate CA, trusted by our Xcalar Root CA. This CA
can publish trusted certificates for hostnames

    $ vault write -format=json xcalar_ca/issue/int-xcalar-com common_name=freenas2.int.xcalar.com alt_names="freenas2" ip=10.10.1.107

## Reading secrets from Vault

For example, we store the GCP service account json data to administer DNS in vault:

    $ vault read -format=json secret/google-dnsadmin | jq -r '.data.data|fromjson' | jq | tee service.json
