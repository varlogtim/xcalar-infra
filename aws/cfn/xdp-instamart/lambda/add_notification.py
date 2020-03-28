import json
import boto3
from crhelper import CfnResource

helper = CfnResource()

SUCCESS = "SUCCESS"
FAILED = "FAILED"


@helper.create
@helper.update
def cr_add_notification(event, _):
    LambdaArn = event['ResourceProperties']['LambdaArn']
    Bucket = event['ResourceProperties']['Bucket']
    Prefix = event['ResourceProperties']['Prefix']
    add_notification(LambdaArn, Bucket, Prefix)


@helper.delete
def cr_delete(event, _):
    Bucket = event['ResourceProperties']['Bucket']
    delete_notification(Bucket)


def lambda_handler(event, context):
    helper(event, context)


def add_notification(LambdaArn, Bucket, Prefix):
    s3 = boto3.resource('s3')
    bucket_notification = s3.BucketNotification(Bucket)
    response = bucket_notification.put(
        NotificationConfiguration={
            'LambdaFunctionConfigurations': [{
                'LambdaFunctionArn': LambdaArn,
                'Events': ['s3:ObjectCreated:*', 's3:ObjectRemoved:*'],
                'Filter': {
                    'Key': {
                        'FilterRules': [{
                            'Name': 'prefix',
                            'Value': Prefix
                        }]
                    }
                }
            }]
        })
    print(json.dumps(response))
    print("Put request completed....")


def delete_notification(Bucket):
    s3 = boto3.resource('s3')
    bucket_notification = s3.BucketNotification(Bucket)
    response = bucket_notification.put(NotificationConfiguration={})
    print("Delete request completed....")
    print(json.dumps(response))