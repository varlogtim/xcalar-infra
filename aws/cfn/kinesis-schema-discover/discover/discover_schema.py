#!/usr/bin/env python3
import boto3


class DiscoverSchemaStack():
    def __init__(self, stack_name):
        self.stack_name = stack_name
        self.client = boto3.client('cloudformation')

    def get_stack_resource(self, logical_id):
        res = self.client.describe_stack_resource(
            StackName=self.stack_name,
            LogicalResourceId=logical_id)['StackResourceDetail']
        return res

    def get_iam_role(self, role_name):
        iam = boto3.client('iam')
        role = iam.get_role(RoleName=role_name)['Role']
        return role

    def get_role_arn(self, logical_role_resource_name):
        role = self.get_stack_resource(logical_role_resource_name)
        iam_role = self.get_iam_role(role['PhysicalResourceId'])
        return iam_role['Arn']

class DiscoverSchemaResult():
    def __init__(self, bucket, key, data):
        self.bucket = bucket
        self.key = key
        self.data = data
        self.schema = data['InputSchema']

class DiscoverSchema():
    def __init__(self, role_arn, client=None):
        self.role_arn = role_arn
        self.client = client if client else boto3.client('kinesisanalyticsv2')
    def discover(self, bucket, key):
        discovered = self.client.discover_input_schema(
            ServiceExecutionRole=self.role_arn,
            S3Configuration={
                'BucketARN': f'arn:aws:s3:::{bucket}',
                'FileKey': key
            })
        return DiscoverSchemaResult(bucket, key, discovered)
