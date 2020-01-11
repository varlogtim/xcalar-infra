#!/usr/bin/env python3
import os
import sys
import json
import boto3
import botocore.exceptions
from discover.discover_schema import DiscoverSchema

# Figure out the KinesisServiceRole ahead of time, like we do in Lambda, then set the
# correct env for it. This saves a whole bunch of time/api calls. In Lamda we also cache
# the top level client to kinesis, because this file is imported once, but the classes/functions
# are instantiated potentially many more times
KINESIS_ROLE_ARN = os.getenv('KINESIS_ROLE_ARN', None)
KINESIS_CLIENT = boto3.client('kinesisanalyticsv2')

# Get the RoleARN form a CloudFormation stack
def stack_role_arn(stack_name, role_name):
    cfn = boto3.client('cloudformation')
    iam = boto3.client('iam')
    role_res = cfn.describe_stack_resource(
        StackName=stack_name,
        LogicalResourceId=role_name)['StackResourceDetail']
    role_arn = iam.get_role(RoleName=role_res['PhysicalResourceId'])['Role']
    return role_arn['Arn']

def bucket_and_key(uri):
    bnk = uri[5:].split('/')
    return (bnk[0], '/'.join(bnk[1:]))

if 'AWS_EXECUTION_ENV' in os.environ:
    pass

if not KINESIS_ROLE_ARN:
    KINESIS_ROLE_ARN = stack_role_arn('DiscoverSchemaStack',
                                      'KinesisServiceRole')
if __name__ == '__main__':
    if len(sys.argv) > 1:
        s3uri = sys.argv[1]
    else:
        sys.stderr.write("Must specify s3url to analyze")
        sys.exit(2)

    if s3uri.index('s3://') != 0:
        sys.stderr.write("s3uri parameter must start with a s3://")
        sys.exit(1)
    if s3uri.index('s3://') != 0:
        raise Exception("Invalid S3 URI")
    bucket, key = bucket_and_key(s3uri)

    try:
        ds = DiscoverSchema(KINESIS_ROLE_ARN, KINESIS_CLIENT)
        schema = ds.discover(bucket, key)
    except botocore.exceptions.ClientError as e:
        raise e
    except Exception as e:
        raise e
    print(json.dumps(schema['InputSchema']))
