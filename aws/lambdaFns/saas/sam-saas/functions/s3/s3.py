import boto3
import json
import traceback
from enums.status_enum import Status
from util.http_util import _http_status, _make_reply
from util.cfn_util import get_stack_info
from util.user_util import get_user_info

# Intialize all service clients
cfn_client = boto3.client('cloudformation', region_name='us-west-2')
dynamodb_client = boto3.client('dynamodb', region_name='us-west-2')

# XXX To-do Read from env variables
user_table = 'saas_user'

def get_bucket(user_name):
    response = get_user_info(dynamodb_client, user_name, user_table)
    if 'Item' not in response:
        return _make_reply(_http_status(response), {
            'status': Status.USER_NOT_FOUND,
            'error': "%s does not exist" % user_name
        })
    cfn_id = response['Item']['cfn_id']['S']
    try:
        stack_info = get_stack_info(cfn_client, cfn_id)
    except Exception as e:
        return _make_reply(200, {
            'status': Status.STACK_NOT_FOUND
        })
    if 's3_url' not in stack_info:
        return _make_reply(200, {
            'status': Status.S3_BUCKET_NOT_EXIST
        })
    return stack_info['s3_url']

def upload_file(upload_params):
    user_name = upload_params['user_name']
    file_name = upload_params['file_name']
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
    user_name = delete_params['user_name']
    file_name = delete_params['file_name']
    # TODO: varify user cookie and get access keys
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    s3_client = boto3.client('s3', region_name='us-west-2')#, aws_access_key_id='AKIAQUNDR55NZCQP53QX', aws_secret_access_key='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')
    s3_client.delete_file(bucket_resp, file_name)
    return _make_reply(200, {
        'status': Status.OK
    })

def bucket_info(user_name):
    bucket_resp = get_bucket(user_name)
    if type(bucket_resp) != str:
        return bucket_resp
    return _make_reply(200, {
        'status': Status.OK,
        'bucket_name': bucket_resp,
        'access_key': 'AKIAQUNDR55N7SAHSRA3',
        'secret_key': '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'
    })

def lambda_handler(event, context):
    try:
        path = event['path']
        data = json.loads(event['body'])
        if path == '/s3/upload':
            reply = upload_file(data)
        if path == '/s3/delete':
            reply = delete_file(data)
        elif path == '/s3/describe':
            reply = bucket_info(data['user_name'])
        else:
            reply = _make_reply(400, "Invalid endpoint: %s" % path)
    except Exception as e:
        traceback.print_exc()
        reply = _make_reply(400, "Exception has occured: {}".format(e))
    return reply