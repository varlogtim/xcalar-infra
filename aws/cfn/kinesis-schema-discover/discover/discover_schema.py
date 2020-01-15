#!/usr/bin/env python3
import boto3
from botocore.exceptions import ClientError


class DiscoverSchemaResult():
    def __init__(self, bucket, key, data):
        self.bucket = bucket
        self.key = key
        self.data = data['ParsedInputRecords']
        self.schema = data['InputSchema']

class DiscoverSchema():
    def __init__(self, role_arn, client=None):
        self.role_arn = role_arn
        self.client = client if client else boto3.client('kinesisanalyticsv2')

    def discover(self, bucket, key):
        discovered = self.client.discover_input_schema(ServiceExecutionRole=self.role_arn,
                                                       S3Configuration={
                                                           'BucketARN': f'arn:aws:s3:::{bucket}',
                                                           'FileKey': key
                                                       })
        return DiscoverSchemaResult(bucket, key, discovered)
