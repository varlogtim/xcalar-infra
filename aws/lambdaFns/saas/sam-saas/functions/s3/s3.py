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

def upload_file(upload_params):
    user_name = upload_params['user_name']
    file_name = upload_params['file_name']
    data = upload_params['data']
    # TODO: varify user cookie and get access keys
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
    bucket_name = stack_info['s3_url']
    temp_file_path = '/tmp/' + file_name
    s3_client = boto3.client('s3', region_name='us-west-2')#, aws_access_key_id = credential['AccessKeyId'], aws_secret_access_key = credential['SecretKey'])
    # Write to local storage might take some time
    filehandle = open(temp_file_path, 'w')
    filehandle.write(data)
    filehandle.close()
    s3_client.upload_file(temp_file_path, bucket_name, file_name, ExtraArgs=None, Callback=None, Config=None)
    return _make_reply(200, {
        'status': Status.OK
    })

def lambda_handler(event, context):
    try:
        path = event['path']
        data = json.loads(event['body'])
        if path == '/s3/put':
            reply = upload_file(data['params'])
        else:
            reply = _make_reply(400, "Invalid endpoint: %s" % path)
    except Exception as e:
        traceback.print_exc()
        reply = _make_reply(400, "Exception has occured: {}".format(e))
    return reply