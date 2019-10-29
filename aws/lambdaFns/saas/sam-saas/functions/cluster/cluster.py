import boto3
import json
import traceback
import socket
import requests
import re
import os

from enums.status_enum import Status
from util.http_util import _http_status, _make_reply, _make_options_reply, _replace_headers_origin
from util.cfn_util import get_stack_info
from util.user_util import init_user, reset_user_cfn, get_user_info, update_user_info, check_user_credential, validate_user_instance
from util.billing_util import get_price
from constants.cluster_type import cluster_type_table

# Intialize all service clients
cfn_client = boto3.client('cloudformation', region_name='us-west-2')
ec2_client = boto3.client('ec2', region_name='us-west-2')
dynamodb_client = boto3.client('dynamodb', region_name='us-west-2')
domain = os.environ.get('DOMAIN')

# XXX To-do Read from env variables
user_table = os.environ.get('USER_TABLE')
billing_table = os.environ.get('BILLING_TABLE')

cfn_role_arn = os.environ.get('CFN_ROLE_ARN')
default_credit = '500'

def get_available_stack(user_name):
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
                    ret_struct['tags'].append({'Key':'Owner', 'Value': user_name})
                    return ret_struct

def start_cluster(user_name, cluster_params):
    # if the user has a cfn stack
    response = get_user_info(dynamodb_client, user_name, user_table)
    if 'Item' not in response:
        return _make_reply(_http_status(response), {
            'status': Status.USER_NOT_FOUND,
            'error': '%s does not exist' % user_name
        })
    user_info = response['Item']
    parameters = []
    is_new = False # whether this is a new user
    tags = cfn_id = cluster_type = response = None
    if 'cfn_id' in user_info:
        cfn_id = user_info['cfn_id']['S']
    else:
        #or we give him an available one
        stack_info = get_available_stack(user_name)
        if stack_info is None:
            return _make_reply(200, {
                'status': Status.NO_AVAILABLE_STACK,
                'error': 'No available stack at this moment'
            })
        cfn_id = stack_info['cfn_id']
        tags = stack_info['tags']
        is_new = True

    if 'type' in cluster_params and cluster_params['type'] in cluster_type_table:
        cluster_type = cluster_type_table[cluster_params['type']]
    else:
        # default to use 'XS'
        cluster_type = cluster_type_table['XS']

    parameters = [
        {
            'ParameterKey': 'ClusterSize',
            'ParameterValue': cluster_type['clusterSize']
        },
        {
            'ParameterKey': 'InstanceType',
            'ParameterValue': cluster_type['instanceType']
        },
        {
            'ParameterKey': 'CNAME',
            'UsePreviousValue': True
        },
        {
            'ParameterKey': 'AuthStackName',
            'UsePreviousValue': True
        },
        {
            'ParameterKey': 'MainStackName',
            'UsePreviousValue': True
        },
        {
            'ParameterKey': 'License',
            'UsePreviousValue': True
        }
    ]
    if 'AMI' in cluster_params:
        parameters.append(
            {
                'ParameterKey': 'ImageId',
                'ParameterValue': cluster_params['AMI']
            }
        )
    else:
        parameters.append(
            {
                'ParameterKey': 'ImageId',
                'UsePreviousValue': True
            }
        )
    if is_new == False:
        response = cfn_client.update_stack(
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
    response = cfn_client.update_stack(
        StackName = cfn_id,
        UsePreviousTemplate = True,
        Parameters = [
            {
                'ParameterKey': 'ClusterSize',
                'ParameterValue': "0"
            },
            {
                'ParameterKey': 'InstanceType',
                'UsePreviousValue': True
            },
            {
                'ParameterKey': 'ImageId',
                'UsePreviousValue': True
            },
            {
                'ParameterKey': 'CNAME',
                'UsePreviousValue': True
            },
            {
                'ParameterKey': 'AuthStackName',
                'UsePreviousValue': True
            },
            {
                'ParameterKey': 'MainStackName',
                'UsePreviousValue': True
            },
            {
                'ParameterKey': 'License',
                'UsePreviousValue': True
            }

        ],
        Capabilities=[
            'CAPABILITY_IAM',
        ],
        RoleARN=cfn_role_arn
    )
    return _make_reply(_http_status(response), {'status': Status.OK})

def check_cluster_status(user_name, stack_info):
    #size = 0, no running cluster
    #directly return
    if stack_info['size'] == 0:
        return {'status': Status.OK,
                'isPending': False}
    else:
        cluster_count = stack_info['size']
        response = ec2_client.describe_instances(
            Filters = [
                {
                    'Name': 'tag:Owner',
                    'Values': [
                        user_name
                    ]
                }
            ]
        )
        running_count = 0
        cluster_info = response['Reservations']
        # listing clusters will also include terminated one
        # cannot check len(cluster_info) == size
        # check: running_count == size
        for i in range(len(cluster_info)):
            instances = cluster_info[i]['Instances']
            #pending case
            for j in range(len(instances)):
                cluster = instances[j]
                if cluster['State']['Name'] == 'pending':
                    return {'status': Status.OK,
                            'isPending': True,
                            'isStarting': True}
                #all running, keep counting
                elif cluster['State']['Name'] == 'running':
                    running_count = running_count + 1
                elif cluster['State']['Name'] == 'terminated' or cluster['State']['Name'] == 'shutting-down':
                    continue
                else:
                    # some clusters are "stopped"/ "stopping"
                    # shouldn't happen, something wrong
                    return {'status': Status.CLUSTER_ERROR,
                            'error': 'Some clusters stop running'}
        #The number of running cluster must equal to size
        # else something wrong
        if running_count == cluster_count:
            # One last check to make sure the url is available
            s = socket.socket()
            try:
                s.settimeout(0.5)
                s.connect((stack_info['cluster_url'].split('https://', 1)[-1], 443))
                r = requests.get(stack_info['cluster_url'] + '/app/service/status', verify=False)
                if r.status_code != 200:
                    return {'status': Status.OK,
                            'isPending': True,
                            'isStarting': True}
                r = requests.get(stack_info['cluster_url'] + '/assets/htmlFiles/login.html', verify=False)
                if r.status_code != 200:
                    return {'status': Status.OK,
                            'isPending': True,
                            'isStarting': True}
            except Exception as e:
                return {'status': Status.OK,
                        'isPending': True,
                        'isStarting': True}
            finally:
                s.settimeout(None)
                s.close()
            return {'status': Status.OK,
                    'clusterUrl': stack_info['cluster_url'],
                    'clusterPrice': get_price(stack_info['type'], cluster_count),
                    'isPending': False}
        else:
            return {'status': Status.STACK_ERROR,
                    'error': 'The number of clusters is wrong'}


def get_cluster(user_name):
    user_info = get_user_info(dynamodb_client, user_name, user_table)
    if 'Item' not in user_info:
        response = init_user(dynamodb_client, user_name, default_credit, user_table, billing_table)
        return _make_reply(_http_status(response), {
            'status': Status.OK,
            'isPending': False
        })
    elif 'cfn_id' not in user_info['Item']:
        return  _make_reply(200, {
            'status': Status.OK,
            'isPending': False
        })
    cfn_id = user_info['Item']['cfn_id']['S']
    stack_info = get_stack_info(cfn_client, cfn_id)
    if 'errorCode' in stack_info:
        if _http_status(reset_user_cfn(dynamodb_client, user_name, user_table)) != 200:
            error = 'Stack %s not found and failed to clean user table' % cfn_id
        else:
            error = 'Stack %s not found' % cfn_id
        return _make_reply(stack_info['errorCode'], {
            'status': Status.STACK_NOT_FOUND,
            'error': error
        })
    # To-do more detailed stack status
    else:
        # in progresss
        if stack_info['stack_status'].endswith('IN_PROGRESS'):
            return _make_reply(200, {
                'status': Status.OK,
                'isPending': True,
                'isStarting': False if stack_info['size'] == 0 else True
            })
        #updated completed, then check cluster status
        elif stack_info['stack_status'] == 'UPDATE_COMPLETE':
            cluster_status = check_cluster_status(user_name, stack_info)
            credit_change = str(-1 * get_price(stack_info['type'], stack_info['size']))
            return _make_reply(200, cluster_status)
        #error(more detailed failure check)
        else:
            return _make_reply(200, {
                'status': Status.STACK_ERROR,
                'error': 'Stack has error: %s' % stack_info['stack_status'],
            })

def lambda_handler(event, context):
    try:
        path = event['path']
        headers = event['headers']
        headers_origin = '*'
        headers_cookies = None
        for key, headerLine in headers.items():
            if (key.lower() == "origin"):
                headers_origin = headerLine
            if (key.lower() == "cookie"):
                headers_cookies = headerLine
        if headers_origin == '*':
            data = json.loads(event['body'])
            if 'username' not in data or 'instanceId' not in data or validate_user_instance(ec2_client, data['username'], data['instanceId']) != True:
                return _make_reply(401, {
                    'status': Status.AUTH_ERROR,
                    'error': 'Authentication failed'
                }, headers_origin)

        elif re.match('^https://\w+.'+domain, headers_origin, re.M|re.I):
            if (event['httpMethod'] == 'OPTIONS'):
                return _make_options_reply(200,  headers_origin)
            data = json.loads(event['body'])
            credential, username = check_user_credential(dynamodb_client, headers_cookies)
            if credential == None or username != data['username']:
                return _make_reply(401, {
                    'status': Status.AUTH_ERROR,
                    'error': "Authentication Failed"
                }, headers_origin)
        else:
            return _make_reply(403, "Forbidden",  headers_origin)

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
    reply = _replace_headers_origin(reply, headers_origin)
    return reply
