import boto3
import json
import traceback

from enums.status_enum import Status
from util.http_util import _http_status, _make_reply
from util.cfn_util import get_stack_info
from util.user_util import init_user, get_user_info, update_user_info
from constants.cluster_type import cluster_type_table

# Intialize all service clients
cfn_client = boto3.client('cloudformation', region_name='us-west-2')
ec2_client = boto3.client('ec2', region_name='us-west-2')
dynamodb_client = boto3.client('dynamodb', region_name='us-west-2')

# XXX To-do Read from env variables
user_table = 'saas_user'
billing_table = 'saas_billing'
# cfn_role_arn = 'arn:aws:iam::559166403383:role/AWS-For-Users-CloudFormation'
cfn_role_arn = 'arn:aws:iam::043829555035:role/AWSCloudFormationAdmin'
default_credit = '500'

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
                        'cfn_id': stack['StackId'],
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
    response = get_user_info(dynamodb_client, user_name, user_table)
    if 'Item' not in response:
        return _make_reply(_http_status(response), {
            'status': Status.USER_NOT_FOUND,
            'error': "%s does not exist" % user_name
        })
    user_info = response['Item']
    tags = None
    s3_url = None
    cluster_url = None
    if 'cfn_id' in user_info:
        cfn_id = user_info['cfn_id']['S']
        stack_info = get_stack_info(cfn_client, cfn_id)
        if 'error' in stack_info:
            return _make_reply(_http_status(stack_info['error']), {
                'status': Status.STACK_NOT_FOUND,
                'error': 'Stack %s not found' % cfn_id
            })
    else:
        # or we give him an available one
        stack_info = get_available_stack()
        cfn_id = stack_info['cfn_id']
        tags = stack_info['tags']

    if stack_info is not None:
        s3_url = stack_info['s3_url']
        cluster_url = stack_info['cluster_url']

    parameters = []
    cluster_type = None
    if 'clusterType' in cluster_params and cluster_params['clusterType'] in cluster_type_table:
        cluster_type = cluster_type_table[cluster_params['clusterType']]
    else:
        # default to use 'small'
        cluster_type = cluster_type_table['small']
    parameters.append(
        {
            'ParameterKey': 'ClusterSize',
            'ParameterValue': cluster_type['clusterSize'],
            'UsePreviousValue': False
        }
    )
    parameters.append(
        {
            'ParameterKey': 'InstanceType',
            'ParameterValue': cluster_type['instanceType'],
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
    response = update_user_info(dynamodb_client, user_info, updates, user_table)

    return _make_reply(_http_status(response), {
        'status': Status.OK
    })

def stop_cluster(user_name):
    user_info = get_user_info(dynamodb_client, user_name, user_table)
    if 'Item' not in user_info:
        return _make_reply(_http_status(user_info), {
            "status": Status.USER_NOT_FOUND,
            "error": "%s does not exist" % user_name
        })
    if 'cfn_id' not in user_info['Item']:
        return _make_reply(_http_status(user_info), {
            'status': Status.NO_STACK,
            'error': '%s does not have a stack' % user_name
        })
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
    updates = {
        'cluster_url': {
            'NULL': True
        }
    }
    response = update_user_info(dynamodb_client, user_info['Item'], updates, user_table)

    return _make_reply(_http_status(response), {'status': Status.OK})

def get_cluster(user_name):
    user_info = get_user_info(dynamodb_client, user_name, user_table)
    if 'Item' not in user_info:
        response = init_user(dynamodb_client, user_name, default_credit, user_table, billing_table)
        return _make_reply(_http_status(response), {
            'status': Status.OK
        })
    elif 'cfn_id' not in user_info['Item']:
        return  _make_reply(200, {
            'status': Status.NO_STACK,
            'error': '%s does not have a stack' % user_name
        })
    cfn_id = user_info['Item']['cfn_id']['S']
    stack_info = get_stack_info(cfn_client, cfn_id)
    if 'error' in stack_info:
        return _make_reply(_http_status(stack_info['error']), {
            'status': Status.STACK_NOT_FOUND,
            'error': 'Stack %s not found' % cfn_id
        })
    # To-do verify cluster is running
    return _make_reply(200, {
        'status': Status.OK,
        'clusterUrl': stack_info['cluster_url']
    })

def lambda_handler(event, context):
    try:
        path = event['path']
        data = json.loads(event['body'])

        if path == '/cluster/start':
            reply = start_cluster(data['username'], data['clusterParams'])
        elif path == '/cluster/stop':
            reply = stop_cluster(data['username'])
        elif path == '/cluster/get':
            reply = get_cluster(data['username'])
        else:
            reply = _make_reply(400, "Invalid endpoint: %s" % path)
    except Exception as e:
        traceback.print_exc()
        reply = _make_reply(400, "Exception has occured: {}".format(e))
    return reply