#!/usr/bin/env python3
import os
import sys
import json
import boto3

#DEFAULT = 's3://xcfield/instantdatamart/json/drugbank_arr/DB05352.json'
DEFAULT = 's3://xcfield/instantdatamart/csv/forecast_canonical.csv'


# Get the RoleARN form a CloudFormation stack
def cfn_getstackRoleArn(stack_name, role_name):
    cfn = boto3.client('cloudformation')
    iam = boto3.client('iam')
    roleRes = cfn.describe_stack_resource(
        StackName=stack_name,
        LogicalResourceId=role_name)['StackResourceDetail']
    roleArn = iam.get_role(RoleName=roleRes['PhysicalResourceId'])['Role']
    return roleArn['Arn']


class DiscoverSchema():
    def __init__(self, role_arn, client=None):
        self.role_arn = role_arn
        self.client = client if client else boto3.client('kinesisanalyticsv2')

    def discover(self, s3uri):
        if s3uri.index('s3://') != 0:
            raise Exception("Invalid S3 URI")
        bucket_and_key = s3uri[5:].split('/')
        bucket, key = (bucket_and_key[0], bucket_and_key[1:])
        return self.client.discover_input_schema(
            ServiceExecutionRole=self.role_arn,
            S3Configuration={
                'BucketARN': f'arn:aws:s3:::{bucket}',
                'FileKey': '/'.join(key)
            })


if 'AWS_EXECUTION_ENV' in os.environ:
    # Figure out the KinesisServiceRole ahead of time, like we do in Lambda, then set the
    # correct env for it. This saves a whole bunch of time/api calls. In Lamda we also cache
    # the top level client to kinesis, because this file is imported once, but the classes/functions
    # are instantiated potentially many more times
    KINESIS_ROLE_ARN = os.environ['KINESIS_ROLE_ARN']
    KINESIS_CLIENT = boto3.client('kinesisanalyticsv2')
else:
    KINESIS_ROLE_ARN = cfn_getstackRoleArn('DiscoverSchemaStack',
                                           'KinesisServiceRole')
    KINESIS_CLIENT = None

if __name__ == '__main__':
    if len(sys.argv) > 1:
        s3uri = sys.argv[1]
    else:
        s3uri = os.getenv('DEFAULT', DEFAULT)

    ds = DiscoverSchema(KINESIS_ROLE_ARN, KINESIS_CLIENT)
    schema = ds.discover(s3uri)
    print(json.dumps(schema['InputSchema']))
