#!/usr/bin/env python3
import os
import sys
import json
import sqlite3
import boto3
import botocore.exceptions
from discover.discover_schema import DiscoverSchemaStack, DiscoverSchema, DiscoverSchemaResult

# Basics we must be provided, given we may not know the RoleARN
STACK_NAME = os.getenv('STACK_NAME', f'DiscoverSchemaStack')
KINESIS_ROLE_NAME = os.getenv('KINESIS_ROLE_NAME', 'KinesisServiceRole')

# The user should try to determine the KinesisServiceRole ARN ahead of time, like we do in Lambda,
# then set the KINESIS_ROLE_ARN environment. This saves a whole bunch of time/api calls.
KINESIS_ROLE_ARN = os.getenv('KINESIS_ROLE_ARN', None)

# We also cache any client sessions by creating the at top level scope. The top level
# scope is only ever loaded/called once, but the classes/functions are instantiated many
# more times. This saves on overhead of extra bringup/teardown of client connection
# objects
KINESIS_CLIENT = boto3.client('kinesisanalyticsv2')


# Return a tuple of (bucketName, keyName) from
# a S3Uri such that s3://foobucket/path/to/key.json
# becomes (foobucket,path/to/key.json)
def bucket_and_key(uri):
    bnk = uri[5:].split('/')
    return (bnk[0], '/'.join(bnk[1:]))


if __name__ == '__main__':
    if len(sys.argv) > 1:
        if sys.argv[1].index('s3://') != 0:
            sys.stderr.write("s3uri parameters must start with a s3://\n")
            sys.exit(1)
    else:
        sys.stderr.write("Must specify s3url to analyze\n")
        sys.exit(2)

    if not KINESIS_ROLE_ARN:
        stack = DiscoverSchemaStack(STACK_NAME)
        KINESIS_ROLE_ARN = stack.get_role_arn(KINESIS_ROLE_NAME)
    try:
        ds = DiscoverSchema(KINESIS_ROLE_ARN, KINESIS_CLIENT)
        for s3arg in sys.argv[1:]:
            bucket, key = bucket_and_key(s3arg)
            discovered = ds.discover(bucket, key)
            json.dumps(discovered.schema)
    except botocore.exceptions.ClientError as e:
        raise e
    except Exception as e:
        raise e
    print(json.dumps(discovered.schema))
