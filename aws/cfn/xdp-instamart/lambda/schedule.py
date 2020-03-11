import os
import uuid
import json
from pathlib import PurePath

import boto3
from botocore.exceptions import ClientError


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
        p = PurePath(f'/{bucket}/{key}')
        name = f'{StackName}-{p.stem}-rule'
        evt = e['eventName'].split(':')[0]
        try:
            if evt == 'ObjectRemoved':
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
                    "Comment": "Insert your JSON here",
                    "ClusterSize": 1,
                    "ClusterName": "-".join(['cluster',p.stem,uid]),
                    "Script": "s3://sharedinf-lambdabucket-559166403383-us-west-2/xdp-instamart/batch.py",
                    "KeepCluster": False
                }
                if 'schedule' in schedreq:
                    schedule = schedreq['schedule']
                    if not any([schedule.startswith(s) for s in ['rate(', 'cron(']]):
                        schedule = 'cron(' + schedule + ')'
                    params['schedule'] = schedule
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
                                              'Id': 'target1',
                                              'Arn': os.environ['StateMachineArn'],
                                              'RoleArn': os.environ['EventRoleArn'],
                                              'Input': json.dumps(params)
                                          }])
                print(json.dumps(response))
        except ClientError as e:
            #ec = response['Error']['Code']
            #print(f'Error: {ec} when handling {evt}:{evt_op} on {name}.')
            print(e)
