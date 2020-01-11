import os
import sys
import json
import boto3

from discover_schema import DiscoverSchema

KINESIS_ROLE_ARN = os.getenv('KINESIS_ROLE_ARN', 'arn:aws:iam::559166403383:role/DiscoverSchemaStack-KinesisServiceRole-13H849V04DH21')
KINESIS_CLIENT = boto3.client('kinesisanalyticsv2')

ds = DiscoverSchema(KINESIS_ROLE_ARN, KINESIS_CLIENT)

def lambda_handler(event, context):
    data = None
    print(type(event))
    if type(event) == type({}):
        if 'queryStringParameters' in event:
            data = event['queryStringParameters']
        elif 'bucket' in event:
            data = event
        elif 'message' in event:
            data = event['message']
    print(event, data)
    if data:
        bucket = data['bucket']
        key = data['key']
        schema = ds.discover(bucket, key)
        inputSchema = schema['InputSchema']
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": json.dumps(inputSchema)
            }),
        }
    return {"statusCode": 400, "body": json.dumps({"message":"No valid data provided"})}
