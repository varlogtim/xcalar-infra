import time
import base64
from urllib.parse import unquote
import boto3
import json
import requests

authCookieName = 'connect.sid'
rawAuthCookie = ""
sessionPrefix = "xc"
sessionTableName = "saas-auth-session-table"
deltaTime = 60
def check_user_credential(dynamodb_client, cookies):
    authCookie = extractCookieValue(cookies)
    if authCookie is None:
        return None, None
    response = dynamodb_client.get_item(TableName=sessionTableName,
                                ConsistentRead=True,
                                Key={
                                    'id': {'S': sessionPrefix + authCookie}
                                })
    if 'Item' not in response:
        return None, None
    sessionInfo = json.loads(response['Item']['sess']['S'])
    if 'idToken' not in sessionInfo:
        return None, None
    idToken = parseJWT(sessionInfo['idToken'])
    if (int(time.time())-deltaTime > idToken['exp']):
        sessionInfo = refreshSession(dynamodb_client, sessionInfo, idToken, authCookie)
    cognitoLogins = {}
    cognitoLogins[sessionInfo['awsLoginString']] = sessionInfo['idToken']
    cognitoClient = boto3.client('cognito-identity')
    cognitoCreds = cognitoClient.get_credentials_for_identity(
                    IdentityId=sessionInfo['identityId'],
                    Logins=cognitoLogins)
    return cognitoCreds, sessionInfo['username']

def refreshSession(dynamodb_client, sessionInfo, idToken, authCookie):
    # if the idToken is expired, we can use the refreshToken to directly
    # request one since boto3 does not expose the InitiateAuth interface.
    postData = {
        'ClientId': idToken['aud'],
        'AuthFlow': 'REFRESH_TOKEN_AUTH',
        'AuthParameters': {
            'REFRESH_TOKEN': sessionInfo['refreshToken'],
        }
    }
    postHeaders = {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth'
    }
    postUrl = 'https://cognito-idp.' + sessionInfo['region'] + '.amazonaws.com'
    refreshReq = requests.post(postUrl, data=json.dumps(postData),
                               headers=postHeaders)
    updateData = refreshReq.json()
    sessionInfo['idToken'] = updateData['AuthenticationResult']['IdToken']
    sessionInfo['accessToken'] = \
        updateData['AuthenticationResult']['AccessToken']
    updateResponse = dynamodb_client.update_item(TableName=sessionTableName,
                             Key={
                                 'id': {'S': sessionPrefix + authCookie}
                             },
                             UpdateExpression='SET sess = :v1',
                             ExpressionAttributeValues={
                                 ':v1': {'S': json.dumps(sessionInfo)}
                             })
    return sessionInfo

def parseJWT(data):
    # A JWT has three parts separated by '.' characers:
    # <header>.<payload>.<signature> We could use a JWT library to do the
    # decode, but more generic techniques (including restoring missing base64
    # padding) will work too.
    tokenPayload = data.split('.')[1] + "="
    missing_padding = len(tokenPayload) % 4
    if missing_padding:
        tokenPayload += '=' * (4 - missing_padding)
    return json.loads(base64.b64decode(tokenPayload))

def extractCookieValue(cookies):
    #
    # First extract the cookie value
    #
    # - The header tag is some version of cookie/Cookie/COOKIE
    # - The cookie header contains a list of cookies separated by '; ':
    #   <name>=<value>[; <name=<value>]*
    # - The cookie has the following syntax: <cookie name>=<cookie value>
    # - The default Xcalar session cookie name is connect.sid
    # - The cookie value is separated into two parts:
    #   <cookie payload>.<signature>
    # - So, we want this:  connect.sid=<part we want>.<signature>
    #
    try:
        rawCookies = cookies.split('; ')
        for cookie in rawCookies:
            if (cookie.startswith(authCookieName)):
                lidx = cookie.find('=')
                ridx = cookie[(lidx+1):].find('.')
                rawAuthCookie = cookie[(lidx+1):(lidx+1+ridx)]
                # it turns out the cookie is signed with a urlencoded
                # 's:' at the beginning
                return unquote(rawAuthCookie)[2:]
    except Exception as e:
        return None

def init_user(client, user_name, credit, user_table, billing_table):
    user_data = {
        'user_name': {'S':user_name}
    }
    credit_data = {
        'user_name': {
            'S':user_name
        },
        'timestamp': {
            'N': str(round(time.time() * 1000))
        },
        'credit_change': {
            'N': credit
        }
    }
    #TODO edge cases
    #insert user table sucessfully
    #but fail to insert into credit table
    response = client.put_item(
        TableName = user_table,
        Item = user_data
    )
    response = client.put_item(
        TableName = billing_table,
        Item = credit_data
    )
    return response

def get_user_info(client, user_name, user_table):
    # To-do handle edge case where user is not found
    return client.get_item(
        TableName=user_table,
        Key={
            'user_name': {
                'S': user_name
            }
        }
    )

def update_user_info(client, user_info, updates, user_table):
    update_expr = 'set'
    expr_values = {}
    for name in updates:
        value = updates[name]
        var_name = ':' + name.split('_')[0]
        update_expr += ' ' + name + ' = ' + var_name + ','
        expr_values[var_name] = value

    response = client.update_item(
        TableName=user_table,
        Key={
            'user_name': {
                'S': user_info['user_name']['S']
            }
        },
        UpdateExpression=update_expr[:-1],
        ExpressionAttributeValues=expr_values
    )
    return response

def reset_user_cfn(client, user_name, user_table):
    return client.update_item(
        TableName=user_table,
        Key={
            'user_name': {
                'S': user_name
            }
        },
        UpdateExpression='remove cfn_id'
    )

def validate_user_instance(ec2_client, user_name, instance_id):
    try:
        response = ec2_client.describe_instances(InstanceIds=[instance_id])
    except Exception as e:
        return False
    if 'Reservations' in response and 'Instances' in response['Reservations'][0] and 'Tags' in response['Reservations'][0]['Instances'][0]:
        tags = response['Reservations'][0]['Instances'][0]['Tags']
        for tag in tags:
            if 'Value' in tag and tag['Key'] == 'Owner' and tag['Value'] == user_name:
                return True
    return False