import boto3
import json
import traceback
import re
import os
from enums.status_enum import Status
from util.http_util import _http_status, _make_reply, _make_options_reply, _replace_headers_origin
from util.cfn_util import get_stack_info
from util.user_util import get_user_info, check_user_credential

# Intialize all service clients
cfn_client = boto3.client('cloudformation', region_name='us-west-2')
dynamodb_client = boto3.client('dynamodb', region_name='us-west-2')
domain = os.environ.get('DOMAIN')
# XXX To-do Read from env variables
user_table = os.environ.get('USER_TABLE')

def get_bucket(user_name):
    response = get_user_info(dynamodb_client, user_name, user_table)
    if 'Item' not in response:
        return _make_reply(_http_status(response), {
            'status': Status.USER_NOT_FOUND,
            'error': "%s does not exist" % user_name
        })
    cfn_id = response['Item']['cfn_id']['S']
    stack_info = get_stack_info(cfn_client, cfn_id)
    if 'errorCode' in stack_info:
        return _make_reply(stack_info['errorCode'], {
            'status': Status.STACK_NOT_FOUND,
            'error': 'Stack %s not found' % cfn_id
        })
    if 's3_url' not in stack_info:
        return _make_reply(200, {
            'status': Status.S3_BUCKET_NOT_EXIST,
            'error': 'Cloud not find s3 given stack %s' % cfn_id
        })
    return stack_info['s3_url']

def upload_file(upload_params):
    user_name = upload_params['username']
    file_name = upload_params['fileName']
    data = upload_params['data']
    # TODO: varify user cookie and get access keys
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    temp_file_path = '/tmp/' + file_name
    s3_client = boto3.client('s3', region_name='us-west-2')#, aws_access_key_id='AKIAQUNDR55NZCQP53QX', aws_secret_access_key='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')
    # Write to local storage might take some time
    filehandle = open(temp_file_path, 'w')
    filehandle.write(data)
    filehandle.close()
    s3_client.upload_file(temp_file_path, bucket_resp, file_name, ExtraArgs=None, Callback=None, Config=None)
    return _make_reply(200, {
        'status': Status.OK
    })

def delete_file(delete_params):
    user_name = delete_params['username']
    file_name = delete_params['fileName']
    # TODO: varify user cookie and get access keys
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    s3_client = boto3.client('s3', region_name='us-west-2')#, aws_access_key_id='AKIAQUNDR55NZCQP53QX', aws_secret_access_key='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')
    s3_client.delete_object(Bucket=bucket_resp, Key=file_name)
    return _make_reply(200, {
        'status': Status.OK
    })

def bucket_info(user_name):
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    return _make_reply(200, {
        'status': Status.OK,
        'bucketName': bucket_resp
    })

def create_multipart_upload(params):
    user_name = params['username']
    file_name = params['fileName']
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    s3_client = boto3.client('s3', region_name='us-west-2')
    create_resp = s3_client.create_multipart_upload(Bucket=bucket_resp, Key=file_name)
    return _make_reply(200, {
        'status': Status.OK,
        'uploadId': create_resp['UploadId']
    })

def upload_part(params):
    user_name = params['username']
    file_name = params['fileName']
    upload_id = params['uploadId']
    data = params['data']
    part_number = params['partNumber']
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    s3_client = boto3.client('s3', region_name='us-west-2')
    upload_resp = s3_client.upload_part(Body=data, Bucket=bucket_resp, Key=file_name, PartNumber=part_number, UploadId=upload_id)
    return _make_reply(200, {
        'status': Status.OK,
        'ETag': upload_resp['ETag']
    })

def complete_multipart_upload(params):
    user_name = params['username']
    file_name = params['fileName']
    upload_id = params['uploadId']
    upload_info = params['uploadInfo']
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    s3_client = boto3.client('s3', region_name='us-west-2')
    s3_client.complete_multipart_upload(Bucket=bucket_resp, Key=file_name, MultipartUpload=upload_info, UploadId=upload_id)
    return _make_reply(200, {
        'status': Status.OK
    })

def abort_multipart_upload(params):
    user_name = params['username']
    file_name = params['fileName']
    upload_id = params['uploadId']
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    s3_client = boto3.client('s3', region_name='us-west-2')
    s3_client.abort_multipart_upload(Bucket=bucket_resp, Key=file_name, UploadId=upload_id)
    return _make_reply(200, {
        'status': Status.OK
    })

def lambda_handler(event, context):
    try:
        path = event['path']
        headers = event['headers']
        headers_origin = '*'
        headers_cookies = None
        for key, headerLine in headers.items():
            if (key.lower() == "origin"):
                headers_origin = headerLine
            if (key.lower() == "cookie"):
                headers_cookies = headerLine
        if re.match('^https://\w+.'+domain, headers_origin, re.M|re.I):
            if (event['httpMethod'] == 'OPTIONS'):
                return _make_options_reply(200,  headers_origin)

            data = json.loads(event['body'])
            credential, username = check_user_credential(dynamodb_client, headers_cookies)
            if credential == None or username != data['username']:
                return _make_reply(401, {
                    'status': Status.AUTH_ERROR,
                    'error': "Authentication Failed"
                },
                headers_origin)
        else:
            return _make_reply(403, "Forbidden",  headers_origin)

        if path == '/s3/upload':
            reply = upload_file(data)
        elif path == '/s3/delete':
            reply = delete_file(data)
        elif path == '/s3/describe':
            reply = bucket_info(data['username'])
        elif path == '/s3/multipart/start':
            reply = create_multipart_upload(data)
        elif path == '/s3/multipart/upload':
            reply = upload_part(data)
        elif path == '/s3/multipart/complete':
            reply = complete_multipart_upload(data)
        elif path == '/s3/multipart/abort':
            reply = abort_multipart_upload(data)
        else:
            reply = _make_reply(400, "Invalid endpoint: %s" % path)

    except Exception as e:
        traceback.print_exc()
        reply = _make_reply(400, "Exception has occured: {}".format(e))
    reply = _replace_headers_origin(reply, headers_origin)
    return reply
