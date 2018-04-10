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

    vault write aws/sts/deploy

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


This time use the `aws-credentials-from-vault.sh` tool to give us the export format.

    $ FILE=creds.json
    $ vault write -format=json aws-xcalar/sts/xcalar-test-poweruser ttl=60m | tee -a $FILE
    {
    "request_id": "f97bbe3d-f38b-f3f0-81ca-495c8a0e6f78",
    "lease_id": "aws-xcalar/sts/xcalar-test-poweruser/5c79416a-3fb3-e48f-b729-9fcc8d185c9f",
    "lease_duration": 3599,
    "renewable": false,
    "data": {
        "access_key": "ASIAIGMPSY7GQBWXQPOQ",
        "secret_key": "FgenSixnrcK4C681RKwEUpLcMebf4hj2vFWzUFx4",
        "security_token": "FQoDYXdzEPL//////////wEaDDzdf/auxfPfBmFzwiKUAorLVZvo7Uv1LhSscKf5Wo52Muj/2vXWhQ1FrwZpph3LfjRBonsZ298GFOBHOR33DHDx5UZZSLR0Q7ytc64XcI2U0lGJnscXdkx0nORk8XRaxzFtteiF83semWuSZy5Qk9YncjYiCakafyBWI44nXNVV0OFe1tTVSWq2PhdxNErwEYfQqAJns78qIwaoYDq2cPyJRMGwwm3ME+KbJhOE42YXX0xtsXLrtmegS9zAUkfDCediA9EHjar4B7ry9ZoV89zFU/K46gr6KsOP0zqg64WVIF0JGdkJkH/JKp25fczqUkzOENtMCiIukkANURrnX4R+3yK7Xnwxvn6BODQQDDY7O5c6v8dLjURJ1/3LHzHMr14d7Cio1LPWBQ=="
    },
    "warnings": null
    }

    $ vault write -format=json aws-xcalar/sts/xcalar-test-poweruser ttl=60m | ./aws-credentials-from-vault.sh --export -f -
    export AWS_ACCESS_KEY_ID=ASIAJXUUZEIJ2UDPAAAA
    export AWS_SECRET_ACCESS_KEY=j7CVAxIskdJsYgdP47snwYqOH8XIbpAPs4RVAAaE
    export AWS_SESSION_TOKEN=FQoDYXdzEPL//////////wEaDAFHHREvjE4VzJ1yASKUAuhK1C2xF+y5IZofgzYYC8t6WlZxzIQqU0wVjQxNqChfhM/X7655HOiFDVYkfC+EH9nHZ0g88vFtCzTq9+mHZqmJwJJ3FUGPEYQlb0aVA4nFbnz//GbdQ6qkKPv2w+tFtmE+S/GGfdw6CpY+82lEdmgV7Ap9rzpl2Ti/cwTwQXDcSZJgRSIyA3TNJ4ECoqyE9XWa2oXWH7aWz/U1IK+rIixGBbUwaFucOIhFVn8IhftUR+LWqKjjsQVRSlj839IwYqfdXuGVdlzvNVjAyJuRymC0jGKgDRt78g6t2YpXdXkegQIAND4mHE4yUCwtd2KS829vsUnZYSTrj7HIqIjO0r3AwxNP0R+zmjcx/We3qW1JL2n8eyjZ2bPWBQ==

You can eval these directly in your session:

    $ eval $(vault write -format=json aws-xcalar/sts/xcalar-test-poweruser ttl=60m | ./aws-credentials-from-vault.sh --export -f -)

You can verify your new identity using `aws sts get-caller-identity`

    $ aws sts get-caller-identity
    {
        "UserId": "AROAJ3DB4ZNGZXGAAAAAA:vault-root-xcalar-test-poweruser-1523371111",
        "Account": "043829551111",
        "Arn": "arn:aws:sts::043829551111:assumed-role/poweruser-role/vault-root-xcalar-test-poweruser-15233784471111"
    }

Before assuming the role, that same call gave me

    $ aws sts get-caller-identity
    {
        "UserId": "AIDAJQRR66ZDXXXX",
        "Account": "5591664111111",
        "Arn": "arn:aws:iam::5591664111111:user/abakshi"
    }

### Integration with AWS cli

The aws cli can call out to an external process and read back the output as a json containing your credentials. Make a small
shell script that calls vault with the role you want to assume, say in `~/bin/awscreds.sh`

```
#!/bin/bash
vault write -format=json aws-xcalar/sts/$1 ttl=60m | ./aws-credentials-from-vault.sh -f -
```

Now try it out, and you'll see the JSON format that awscli is expecting:

    $ chmod +x ~/bin/awscreds.sh
    $ ~/bin/awscreds.sh xcalar-test-poweruser
    {
    "Version": 1,
    "AccessKeyId": "ASIAIGOLICJRBBSGBY5A",
    "SecretAccessKey": "CtLN5qbOGxcI4na12bh8lEfn9PM6EbhQs1K+aMWn",
    "SessionToken": "FQoDYXdzEPL//////////wEaDBG4uny7Vs4mzA2oiCKUAqzVRuRxCycmSksdTodF3A9Hg7MlJlp//lvA5OBBa7npBzBf0mIn+Q+h45dgkxknQEUzFktMgBPfdjVjfj826CeKWLREPgMJvucxCwS/NuMezBGcf3B2JYci9l/0sDl4zlnPjvoiI/ZhUlP6XD3J5nZDAtqarwQLEtth/wZbpQEf0vWFm0wgJc/UFxbo+P4dMzmpZtPi4blZqtdSfdU8vlOImc5Dsts1OQFz0XJNkuVSuazd0Wuf/doxopsXcx7LBpDSIptj0aJsuf8JPErdf8HKCQUOrccpC1lMBA9hPIU5WnenRNXgpzhaZN1PMYZfMg6D3PhX8VTjjluVSoNri3aAapwCM6GLBQjOWVrtjebyPKB3DSie27PWBQ==",
    "Expiration": "2018-04-10T18:00:13.000Z"
    }


In your ~/aws/credentials, adds  a new section

    [xcalar-test-poweruser]
    credential_process = /home/abakshi/bin/awscreds.sh xcalar-test-jenkins

Now you can call into the CLI:

    $ aws --profile xcalar-test-poweruser ec2 describe-instances

The cli will call your script, retrieve the temporary creds from Vault and log you in.


## Login as a service or as a registered machine

Vault has our Puppet CA registerd as a valid means to auth. This means any node that has a signed puppet certificate can log
into vault by providing the client cert and key! This is great for jenkins jobs etc. The paths that this client can access
are specified by the token policies (default prod web). Those are just ones I made up for any machine with a puppet cert.
You can further narrow this down based on puppet roles, or hostnames.

    # vault login -method=cert -client-cert=/etc/puppetlabs/puppet/ssl/certs/jenkins-slave-el7-1.int.xcalar.com.pem  -client-key=/etc/puppetlabs/puppet/ssl/private_keys/jenkins-slave-el7-1.int.xcalar.com.pem

    Success! You are now authenticated. The token information displayed below
    is already stored in the token helper. You do NOT need to run "vault login"
    again. Future Vault requests will automatically use this token.

    Key                            Value
    ---                            -----
    token                          fd514741-d8a7-ceef-ceed-05bb336f4210
    token_accessor                 90faf598-7732-9bc6-9332-f01553ecd40e
    token_duration                 1h
    token_renewable                true
    token_policies                 [default prod web]
    token_meta_subject_key_id      7d:83:29:2d:1a:b6:cd:83:5d:0e:8a:6a:f8:1c:67:c4:03:da:ca:34
    token_meta_authority_key_id    16:55:d9:47:d3:9d:7a:36:46:12:35:65:96:e8:7a:ec:05:d3:7b:63
    token_meta_cert_name           web
    token_meta_common_name         jenkins-slave-el7-1.int.xcalar.com


## Reading secrets from Vault

For example, we store the GCP service account json data to administer DNS in vault:

    $ vault read -format=json secret/google-dnsadmin | jq -r '.data.data|fromjson' | jq | tee service.json

## Writing a secret to Vault

    $ vault write secret/nodes/mykey  data=something foo=bar key=value complex=@file

## Using Vault CA for internal certificates

Vault is configured with an intermediate CA, trusted by our Xcalar Root CA. This CA
can publish trusted certificates for hostnames

    $ vault write -format=json xcalar_ca/issue/int-xcalar-com common_name=freenas2.int.xcalar.com alt_names="freenas2" ip=10.10.1.107

## Vault for SSH Trusted CA auth

You can ask Vault to sign your SSH pub key for you. Once it's signed, you can use the ssh key to log into
any machine that trusts our CA.

    $ vault write -format=json ssh-client-signer/sign/xctest public_key=@$HOME/.ssh/id_rsa.pub
    {
    "request_id": "c1c2b2c7-633a-b421-9a9b-1e38951a6834",
    "lease_id": "",
    "lease_duration": 0,
    "renewable": false,
    "data": {
        "serial_number": "3921948baa1beb25",
        "signed_key": "ssh-rsa-cert-v01@openssh.com AAAAHHNzaC1yc2EtY2VydC12MDFAb3BlbnNzaC5jb20AAAAgadpGXWxFes/wcN9DHMnjVkGvzuo3TJtJUOlhbdGhyyUAAAADAQABAAABAQCxNDrxkrvi6Do
        7swzgoqg6VvyNEfIyLHbIZ3BD6N445VK7q2Ako6HYuFYKQiWdBkmIb99fC0A1hfLgxweppFZ2+aXcFUvitFB2E9BHQ/u2
        MVsgvIqrl/1Q5kJnTCl/y7vVPRScU0YdHVbvEkTeqNr2vk0qYXQUBB4/I2Bt2WS+G9Zr/+R89iADccPMAfE34+FD/+cow
        KNEuhf13xbJx3x4bp7JYMyK6KloHASwx......<snip>"
    },
    "warnings": null
    }

The xctest role was created via:

    cat ssh-client-signer-role.json | vault write ssh-client-signer/roles/xctest
Save just the signed key (which is just another SSH pub key):

    $ vault write -field=signed_key ssh-client-signer/sign/xctest public_key=@$HOME/.ssh/id_rsa.pub > ~/.ssh/id_rsa-cert.pub

    # View the properties
    $ ssh-keygen -Lf ~/.ssh/id_rsa-cert.pub
        Type: ssh-rsa-cert-v01@openssh.com user certificate
        Public key: RSA-CERT SHA256:qdNGV0z+ljzCmMsKNWGzTbCXhd3tP5YbKVDlaeo4LuY
        Signing CA: RSA SHA256:LXzx4EzCIigK+cuYqJy1z08oQ605AVep4YDx6uc1N5s
        Key ID: "vault-root-a9d346574cfe963cc298cb0a3561b34db09785dded3f961b2950e569ea382ee6"
        Serial: 5348601710082418928
        Valid: from 2018-04-10T11:18:46 to 2018-04-10T11:49:16
        Principals:
                jenkins
        Critical Options: (none)
        Extensions:
                permit-pty

Now you can ssh into any instance that has the TrustedUserCAKey set in sshd_config

    $ ssh -i ~/.ssh/signed-cert.pub -i ~/.ssh/id_rsa jenkins@jenkins-slave-el7-1
    Last login: Tue Apr 10 10:30:21 2018 from 10.10.1.208

## Vault as a CA for SSL certs


Get help on the PKI path:

    $ vault path-help pki/issue/int-xcalar-dot-com

Configure it:

    $ vault write pki/roles/int-xcalar-dot-com allowed_domains="int.xcalar.com" allow_subdomains="true" max_ttl="72h"

Issue a cert:

    $ vault write -format=json pki/issue/int-xcalar-dot-com common_name=tesla.int.xcalar.com alt_name="tesla" ip="10.10.4.2"
    {
    "request_id": "08faf5f0-7f18-5709-301d-7fc8ea812e94",
    "lease_id": "",
    "lease_duration": 0,
    "renewable": false,
    "data": {
    "ca_chain": [
        "-----BEGIN CERTIFICATE-----\nMIIF5DCCA8ygAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwgYsxCzAJBgNVBAYTAlVT\nMQswCQYDVQQIDAJDQTERMA8GA1UEBwwIU2FuIEpvc2UxFDASBgNVBAoMC1hjYWxh\nciBJbmMuMSkwJwYDVQQLDCBYY2FsYXIgSW5jIENlcnRpZmljYXRlIEF1dGhvcm","...",".."
    ],
    "certificate": "-----BEGIN CERTIFICATE-----\nMIIFQDCCAyigAwIBAgIUVVS086phA2nL2KjdcP1xwRudT+YwDQYJKoZIhvcNAQEL\nBQAwdjELMAkGA1UEBhMCVVMxCzAJBgNVBAgMAkNBMRQwEgYDVQQKDAtYY2FsYXIg\nSW5jLjEkMCIGA1UECwwbVmF1bHQgQ2VydGlmaWNhdGUgQXV",
    "issuing_ca": "-----BEGIN CERTIFICATE-----\nMIIF5DCCA8ygAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwgYsxCzAJBgNVBAYTAlVT\nMQswCQYDVQQIDAJDQTERMA8GA1UEBwwIU2FuIEpvc2UxFDASBgNVBAoMC1hjYWxh\nciBJbmMuMSkwJwYDVQQLDCBYY2FsYXIgSW5jIENlcnRpZmlj",
    "private_key": "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA3LalZnwZZZ7611m84QgjF7X40v3GkqkevOQgdU/+aOxLXqao\nfLLjG7HD+VXDmguamfptpWOUkTiJszOfbNfZzliR8YC42g0Q+M3+mwlIc/wQJUT5\nbk8AlI9VN9m26K6aXNjP+jjrV0/DF7I7GgSIUK1i633V",
    "private_key_type": "rsa",
    "serial_number": "55:54:b4:f3:aa:61:03:69:cb:d8:a8:dd:70:fd:71:c1:1b:9d:4f:e6"
    },
    "warnings": null
    }

