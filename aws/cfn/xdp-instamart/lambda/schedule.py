import os
import uuid
import json
import gzip
import base64
from pathlib import PurePath

import boto3
import requests
from botocore.exceptions import ClientError


def startstep_handler(event,context):
    print(json.dumps(event))
    print(json.dumps(context))
    step = boto3.client('stepfunctions')
    StateMachineArn = os.environ['StateMachineArn']
    StateMachineName = os.environ['StateMachineName']
    StackName = os.environ['StackName']
    uid = uuid.uuid1().hex
    input = event['Input']
#    = {
#        "Comment": "Insert your JSON here",
#        "ClusterSize": 1,
#        "ClusterName": "Cluster-"+uid,
#        "Input": "dataFlow.xlrwb.tar.gz",
#        "Output": "export/dataFlowOut.txt",
#        "KeepCluster": False
#    }
    name = f'{StackName}-{StateMachineName}-{uid}'
    response = step.start_execution(
        stateMachineArn=StateMachineArn,
        name=name,
        input=json.dumps(input)
    )
    return response['executionArn']

def launchcluster_handler(event, context):
    print(json.dumps(event))
    client = boto3.client('ec2')
    InstanceType = os.environ['InstanceType']
    InstanceArn = os.environ['InstanceArn']
    ClusterName = event['ClusterName']
    ClusterSize = int(event['ClusterSize'])
    LaunchTemplate = os.environ['LaunchTemplate']
    LaunchTemplateVersion = os.environ['LaunchTemplateVersion']
    BaseURL = os.environ['BaseURL']
    EfsSharedRoot = os.environ['EfsSharedRoot']
    Email = os.environ['Email']
    AdminUsername = os.environ['AdminUsername']
    AdminPassword = os.environ['AdminPassword']
    #url = requests.get(f'{BaseURL}scripts/batch.sh')
    userData = f'''\
#!/bin/bash
export ADMIN_USERNAME="{AdminUsername}"
export ADMIN_PASSWORD='{AdminPassword}'
export ADMIN_EMAIL='{Email}'
export CLUSTERNAME='{ClusterName}'
set -x
cd /var/lib/cloud/instance
curl -fsSL -o batch.sh "{BaseURL}scripts/batch.sh"
set -o pipefail
bash -x batch.sh 2>&1 | tee -a /var/log/user-data-batch.log
exit $?
'''
    response = client.run_instances(
        LaunchTemplate={
        'LaunchTemplateId': LaunchTemplate,
        'Version': LaunchTemplateVersion,
        },
        InstanceType=InstanceType,
        IamInstanceProfile={
            'Arn': InstanceArn
        },
        MinCount=int(ClusterSize),
        MaxCount=int(ClusterSize),
        TagSpecifications=[{
        'ResourceType': 'instance',
        'Tags': [
            {'Key': 'Name', 'Value': f'{ClusterName}-vm'},
            {'Key': 'ClusterName', 'Value': ClusterName},
            {'Key': 'ClusterSize', 'Value': str(ClusterSize)},
            {'Key': 'FileSystemId', 'Value': EfsSharedRoot},
            {'Key': 'Owner', 'Value': Email}
        ]
        }],
        UserData=userData
    )
    event['InstanceIds'] = [instance['InstanceId'] for instance in response['Instances']]
    return event

def update_handler(event, _):
    print(json.dumps(event))
    #StackId = os.environ['StackId']
    #
    StackName = os.environ['StackName']
    #EventPrefix = os.environ['EventPrefix']
    s3 = boto3.client('s3')
    eb = boto3.client('events')
    for e in event['Records']:
        bucket = e['s3']['bucket']['name']
        key = e['s3']['object']['key']
        if not key.endswith('.json'):
            continue
        p = PurePath(f'/{bucket}/{key}')
        name = f'{StackName}-{p.stem}-rule'
        evt = e['eventName'].split(':')[0]
        try:
            if evt == 'ObjectRemoved':
                print(f'Removing targets Rule={name}, Ids=["1"]')
                eb.remove_targets(Rule=name,Ids=['1'])
                print(f'Deleting rule Name={name}')
                eb.delete_rule(Name=name)
            if evt == 'ObjectCreated':
                eTag = e['s3']['object']['eTag']
                response = s3.get_object(Bucket=bucket, Key=key, IfMatch=eTag)
                body = response['Body']
                schedreq = json.load(body)
                body.close()
                uid = uuid.uuid1().hex
                params = {
                    "ClusterSize": 1,
                    "ClusterName": "-".join(['cluster',p.stem,uid]),
                    "Script": "s3://sharedinf-lambdabucket-559166403383-us-west-2/xdp-instamart/runner.sh",
                    "KeepCluster": False
                }
                if 'schedule' in schedreq:
                    schedule = schedreq['schedule']
                    if not any([schedule.startswith(s) for s in ['rate(', 'cron(']]):
                        schedule = 'cron(' + schedule + ')'
                    params['Schedule'] = schedule
                if 'input' in schedreq:
                    params['Input'] = schedreq['input']
                if 'output' in schedreq:
                    params['Output'] = schedreq['output']
                if 'cluster_size' in schedreq:
                    params['ClusterSize'] = int(schedreq['cluster_size'])
                if 'command' in schedreq:
                    params['Command'] = schedreq['command']
                print(f'Setting schedule for {name} to {schedule}')
                response = eb.put_rule(Name=name,
                                       ScheduleExpression=schedule,
                                       State='ENABLED',
                                       Tags=[{
                                           'Key': 'Name',
                                           'Value': p.stem
                                       }, {
                                           'Key': 'StackName',
                                           'Value': StackName
                                       }])
                print(json.dumps(response))
                response = eb.put_targets(Rule=name,
                                          Targets=[{
                                              'Id': '1',
                                              'Arn': os.environ['StateMachineArn'],
                                              'RoleArn': os.environ['EventRoleArn'],
                                              'Input': json.dumps(params)
                                          }])
                print(json.dumps(response))
        except ClientError as e:
            #ec = response['Error']['Code']
            #print(f'Error: {ec} when handling {evt}:{evt_op} on {name}.')
            print(e)
        return event
