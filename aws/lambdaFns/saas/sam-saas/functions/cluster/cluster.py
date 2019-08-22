import boto3
import json
import time
from enums.status_enum import Status
# Intialize all service clients
# session = boto3.Session(profile_name='default')
cfn_client = boto3.client('cloudformation', region_name='us-west-2')
ec2_client = boto3.client('ec2', region_name='us-west-2')
dynamodb_client = boto3.client('dynamodb', region_name='us-west-2')

# XXX To-do Read from env variables
user_table = 'saas_user'
credit_table = 'saas_billing'
cfn_role_arn = 'arn:aws:iam::559166403383:role/AWS-For-Users-CloudFormation'
default_credit = '500'

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
            'user_name': {
                'S': user_info['user_name']['S']
            }
        },
        UpdateExpression=update_expr[:-1],
        ExpressionAttributeValues=expr_values
    )
    return response

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

def start_cluster(user_name, cluster_params):
    # if the user has a cfn stack
    response = get_user_info(user_name)
    if 'Item' not in response:
        return _make_reply(_http_status(response), {"status": Status.NO_USER_FOUND, "error": "ursername did not exist"})
    user_info = response['Item']
    tags = None
    s3_url = None
    cluster_url = None
    if 'cfn_id' in user_info:
        cfn_id = user_info['cfn_id']['S']
        response = cfn_client.describe_stacks(StackName=cfn_id)
        if 'Stack' not in response or len(response['Stacks']) == 0:
            return _make_reply(_http_status(response), {
            'status': Status.NO_STACK_FOUND,
            'error': 'Stack %s not found' % cfn_id
            })
        stack_info = response['Stack'][0]
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
    response = update_user_info(user_name, user_info, updates)

    return _make_reply(_http_status(response), {
        'success': True,
        'clusterUrl': cluster_url,
        's3Url': s3_url
    })

def stop_cluster(user_name):
    response = get_user_info(user_name)
    if 'Item' not in response:
        return _make_reply(_http_status(response), {"status": Status.NO_USER_FOUND, "error": "ursername did not exist"})
    user_info = response['Item']
    if 'cfn_id' not in response['Item']:
        return _make_reply(_http_status(response), {"status": Status.NO_STACK_FOUND, "error": "urser did not own a stack"})
    cfn_id = user_info['Item']['cfn_id']['S']
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
    response = update_user_info(user_name, user_info['Item'], updates)

    return _make_reply(_http_status(response), {'success': True})

def get_stack_info(cfn_id):
    cluster_url = None
    response = cfn_client.describe_stacks(StackName=cfn_id)
    if 'Stack' not in response or len(response['Stacks']) == 0:
            return _make_reply(_http_status(response), {
            'status': Status.NO_STACK_FOUND,
            'error': 'Stack %s not found' % cfn_id
            })
    stack_info = response['Stack'][0]
    for output in stack_info['Outputs']:
            if output['OutputKey'] == 'URL':
                cluster_url = output['OutputValue']
    stack_status = stack_info['StackStatus']

    return {'stack_status': stack_status, 'cluster_url':cluster_url}


def get_cluster_url(user_info):
    if 'cfn_idf' in user_info:
        stack_info = get_stack_info(user_info['cfn_id']['S'])
        #TODO: will handle edge case
        if stack_info['stack_status'].endwith('IN_PROGRESS'):
            return _make_reply(200, {'status': Status.CLUSTER_NOT_READY, 'error': stack_info['stack_status']})
        elif stack_info['stack_status'].endwith('Failed'):
            raise Exception('status of stack is failed: ' +stack_info['stack_status'])
        else:
            return _make_reply(200, {'status': Status.OK, 'clusterUrl': stack_info['cluster_url']})

    else:
        return  _make_reply(200, {'status': Status.OK,'clusterUrl': None})

def get_user_info(user_name):
    response = dynamodb_client.get_item(
        TableName = user_table,
        Key = {
            "user_name": {'S':user_name}
        }
    )
    return response


def init_user(user_name):
    user_data = {
        'user_name': {'S':user_name}
    }
    credit_data = {
        'user_name': {'S':user_name},
        'timestamp': {'N': str(round(time.time()*1000))},
        'credit': {'N': default_credit}
    }
    #TODO edge cases
    #insert user table sucessfully
    #but fail to insert into credit table
    response = dynamodb_client.put_item(
        TableName = user_table,
        Item = user_data
    )
    response = dynamodb_client.put_item(
        TableName = credit_table,
        Item = credit_data
    )
    return  _make_reply(_http_status(response), {'status': Status.OK, 'clusterUrl': None})

def get_running_cluster(user_name):
    user_info = get_user_info(user_name)
    if 'Item' not in user_info:
        return init_user(user_name)
    else:
        return get_cluster_url(user_info['Item'])


def lambda_handler(event, context):
    try:
        path = event['path']
        data = json.loads(event['body'])

        if path == '/cluster/start':
            reply = start_cluster(data['userName'], data['clusterParams'])
        elif path == '/cluster/stop':
            reply = stop_cluster(data['userName'])
        elif path == '/cluster/get':
            reply = get_running_cluster(data['userName'])
        else:
            reply = _make_reply(400, "Invalid endpoint: %s" % path)
    except Exception as e:
        print(e)
        reply = _make_reply(400, "Exception has occured: {}".format(e))
    print(reply)
    return reply

def _make_reply(code, message):
    return {"statusCode": code, "body": json.dumps(message)}

def _http_status(resp):
    return resp["ResponseMetadata"]["HTTPStatusCode"]