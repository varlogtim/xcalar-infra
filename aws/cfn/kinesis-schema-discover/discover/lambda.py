import os
import sys
import json
import boto3
import discover_schema

KINESIS_ROLE_ARN = os.environ['KINESIS_ROLE_ARN']
STACK_NAME = os.environ['STACK_NAME']
KINESIS_CLIENT = boto3.client('kinesisanalyticsv2')

ds = discover_schema.DiscoverSchema(KINESIS_ROLE_ARN, KINESIS_CLIENT)


def lambda_handler(event, context):
    data = None
    print(type(event))
    json.dumps(event)
    if type(event) == type({}):
        if 'queryStringParameters' in event:
            data = event['queryStringParameters']
        elif 'bucket' in event:
            data = event
        elif 'message' in event:
            data = event['message']
    if data:
        json.dumps(data)
        bucket = data['bucket']
        key = data['key']
        fmt = data['format'] if 'format' in data else 'schema'

        result = ds.discover(bucket, key)
        if fmt == 'schema':
            output = result.data['InputSchema']
        elif fmt == 'parsed':
            output = result.data['ParsedInputRecords']
        elif fmt == 'full':
            output = result.data
        else:
            return {"statusCode": 401, "body": json.dumps({"message": f"Invalid format={fmt} specified"})}
        return {"statusCode": 200, "body": json.dumps(output)}
    return {"statusCode": 400, "body": json.dumps({"message": "No valid data provided"})}
