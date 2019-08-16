import boto3
import json
import time
# Intialize all service clients
# session = boto3.Session(profile_name='default')
cfn_client = boto3.client('cloudformation', region_name='us-west-2')
ec2_client = boto3.client('ec2', region_name='us-west-2')
dynamodb_client = boto3.client('dynamodb', region_name='us-west-2')

# XXX To-do Read from env variables
user_table = 'CloudTestUserTable'
cfn_role_arn = 'arn:aws:iam::559166403383:role/AWS-For-Users-CloudFormation'

def get_user_info(token):
    # To-do given a token, gimme back the user_id
    return get_user_info_hack(token)
def update_user_info(token, user_info, updates):
    update_expr = 'set'
    expr_values = {}
    for name in updates:
        value = updates[name]
        var_name = ':' + name.split('_')[0]
        update_expr += ' ' + name + ' = ' + var_name + ','
        expr_values[var_name] = value

    response = dynamodb_client.update_item(
        TableName=user_table,
        Key={
            'user_id': {
                'S': user_info['user_id']['S']
            }
        },
        UpdateExpression=update_expr[:-1],
        ExpressionAttributeValues=expr_values
    )
    return response
def get_user_info_hack(token):
    user_id = 'us-west-2:da83d271-0394-4c81-9a3e-7e50235b7115'
    user_info = dynamodb_client.get_item(
        TableName=user_table,
        Key={
            'user_id': {
                'S': user_id
            }
        }
    )
    if 'Item' not in user_info:
        user_info={
            'user_id': {
                'S': user_id
            },
            'user_name': {
                'S': 'test-user-1'
            }
        }
        dynamodb_client.put_item(
            TableName=user_table,
            Item=user_info
        )
    else:
        user_info = user_info['Item']
    return user_info

def get_available_stack():
    all_stacks = cfn_client.describe_stacks()['Stacks']
    available_status = ['CREATE_COMPLETE', 'ROLLBACK_COMPLETE',
                        'UPDATE_COMPLETE', 'UPDATE_ROLLBACK_COMPLETE']
    for stack in all_stacks:
        if stack['StackStatus'] in available_status:
            for i in range(len(stack['Tags'])):
                tag = stack['Tags'][i]
                if 'Value' in tag and tag['Key'] == 'available' and tag['Value'] == 'true':
                    del stack['Tags'][i]
                    ret_struct = {
                        'cfn_id': stack['StackName'],
                        'tags': stack['Tags']
                    }
                    for output in stack['Outputs']:
                        if output['OutputKey'] == 'S3Bucket':
                            ret_struct['s3_url'] = output['OutputValue']
                        elif output['OutputKey'] == 'URL':
                            ret_struct['cluster_url'] = output['OutputValue']
                    return ret_struct


def start_cluster(token, cluster_params):
    # if the user has a cfn stack
    user_info = get_user_info(token)
    tags = None
    s3_url = None
    cluster_url = None
    if 'cfn_id' in user_info:
        cfn_id = user_info['cfn_id']['S']
        stack_info = cfn_client.describe_stacks(StackName=cfn_id)['Stacks'][0]
        for output in stack_info['Outputs']:
            if output['OutputKey'] == 'S3Bucket':
                s3_url = output['OutputValue']
            elif output['OutputKey'] == 'URL':
                cluster_url = output['OutputValue']
    else:
        # or we give him an available one
        stack_info = get_available_stack()
        cfn_id = stack_info['cfn_id']
        tags = stack_info['tags']
        s3_url = stack_info['s3_url']
        cluster_url = stack_info['cluster_url']

    print('creating change set')
    parameters = []
    if 'clusterSize' in cluster_params:
        parameters.append(
            {
                'ParameterKey': 'ClusterSize',
                'ParameterValue': cluster_params['clusterSize'],
                'UsePreviousValue': False
            }
        )
    else:
        parameters.append(
            {
                'ParameterKey': 'ClusterSize',
                'ParameterValue': '1',
                'UsePreviousValue': False
            }
        )
    if 'instanceType' in cluster_params:
        parameters.append(
            {
                'ParameterKey': 'InstanceType',
                'ParameterValue': cluster_params['instanceType'],
                'UsePreviousValue': False
            }
        )
    if 'AMI' in cluster_params:
        parameters.append(
            {
                'ParameterKey': 'AMIUsWest2',
                'ParameterValue': cluster_params['AMI'],
                'UsePreviousValue': False
            }
        )
    if tags is None:
        cfn_client.update_stack(
            StackName=cfn_id,
            UsePreviousTemplate=True,
            Parameters=parameters,
            Capabilities=[
                'CAPABILITY_IAM',
            ],
            RoleARN=cfn_role_arn
        )
    else:
        cfn_client.update_stack(
            StackName=cfn_id,
            UsePreviousTemplate=True,
            Parameters=parameters,
            Capabilities=[
                'CAPABILITY_IAM',
            ],
            RoleARN=cfn_role_arn,
            Tags=tags
        )
    print('updating stack')
    waiter = cfn_client.get_waiter('stack_update_complete')
    waiter.wait(
        StackName=cfn_id
    )
    print('update complete')
    print('updating usre info')
    print(user_info)
    updates = {
        'cfn_id': {
            'S': cfn_id
        },
        'cluster_url': {
            'S': cluster_url
        },
        's3_url': {
            'S': s3_url
        }
    }
    response = update_user_info(token, user_info, updates)

    return _make_reply(_http_status(response), {
        'success': True,
        'clusterUrl': cluster_url,
        's3Url': s3_url
    })

def stop_cluster(token):
    user_info = get_user_info(token)
    cfn_id = user_info['cfn_id']['S']

    cfn_client.update_stack(
        StackName = cfn_id,
        UsePreviousTemplate = True,
        Parameters = [
            {
                'ParameterKey': 'ClusterSize',
                'ParameterValue': "0",
                'UsePreviousValue': False
            }
        ],
        Capabilities=[
            'CAPABILITY_IAM',
        ],
        RoleARN=cfn_role_arn
    )
    waiter = cfn_client.get_waiter('stack_update_complete')
    waiter.wait(
        StackName = cfn_id
    )
    updates = {
        'cluster_url': {
            'NULL': True
        }
    }
    response = update_user_info(token, user_info, updates)

    return _make_reply(_http_status(response), {'success': True})

def lambda_handler(event, context):
    try:
        data = json.loads(event['body'])
        command = data['command']
        print(command)
        if command == 'start_cluster':
            reply = start_cluster(data['token'], data['clusterParams'])
        elif command == 'stop_cluster':
            reply = stop_cluster(data['token'])
        elif command is None:
            reply = _make_reply(400, "Command not specified")
        else:
            reply = _make_reply(400, "Invalid command: %s" % command)
    except Exception as e:
        print(e)
        reply = _make_reply(400, "Exception has occured: {}".format(e))
    print(reply)
    return reply

def _make_reply(code, message):
    return {"statusCode": code, "body": json.dumps(message)}

def _http_status(resp):
    return resp["ResponseMetadata"]["HTTPStatusCode"]