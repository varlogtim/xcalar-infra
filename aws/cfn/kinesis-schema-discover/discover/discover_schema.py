#!/usr/bin/env python3
import os
import sys
import json
import boto3
import botocore.exceptions

def fbar():
    pass

class DiscoverSchema():
    def __init__(self, role_arn, client=None):
        self.role_arn = role_arn
        self.client = client if client else boto3.client('kinesisanalyticsv2')
    def discover(self, bucket, key):
        return self.client.discover_input_schema(
            ServiceExecutionRole=self.role_arn,
            S3Configuration={
                'BucketARN': f'arn:aws:s3:::{bucket}',
                'FileKey': key
            })

if 'AWS_EXECUTION_ENV' in os.environ:
    pass

