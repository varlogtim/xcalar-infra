import boto3
import json
import time
import traceback
from status_enum import Status
# To-do all hard-coded values need to be read from enviornemnt variables
dynamodb_client = boto3.client('dynamodb', region_name='us-west-2')
cfn_client = boto3.client('cloudformation', region_name='us-west-2')
billing_table = 'saas_billing'
user_table = 'saas_user'
price_factor = 1.7
# To-do instead of using a hard-coded pricing table, wire in Cost Explorer API
# Go to https://aws.amazon.com/ec2/pricing/on-demand/
# Run Jerene's code snippet in browser console to get latest pricing:
# var rows = $("body").find("div[data-region='us-west-2']").eq(0).find("tbody tr");
# var pricing = {};
# for (var i = 0; i < rows.length; i++) {
#     if (!rows.eq(i).hasClass("aws-subhead") && rows.eq(i).find("td").length >=6) {
#         var type = rows.eq(i).find("td").eq(0).text();
#         var price = rows.eq(i).find("td").eq(5).text();
        
#         pricing[type] = parseFloat(price.substring(1));
#     }
# }
# JSON.stringify(pricing, undefined, 2)
price_table = {
    "a1.medium": 0.0255,
    "a1.large": 0.051,
    "a1.xlarge": 0.102,
    "a1.2xlarge": 0.204,
    "a1.4xlarge": 0.408,
    "t3.nano": 0.0052,
    "t3.micro": 0.0104,
    "t3.small": 0.0208,
    "t3.medium": 0.0416,
    "t3.large": 0.0832,
    "t3.xlarge": 0.1664,
    "t3.2xlarge": 0.3328,
    "t3a.nano": 0.0047,
    "t3a.micro": 0.0094,
    "t3a.small": 0.0188,
    "t3a.medium": 0.0376,
    "t3a.large": 0.0752,
    "t3a.xlarge": 0.1504,
    "t3a.2xlarge": 0.3008,
    "t2.nano": 0.0058,
    "t2.micro": 0.0116,
    "t2.small": 0.023,
    "t2.medium": 0.0464,
    "t2.large": 0.0928,
    "t2.xlarge": 0.1856,
    "t2.2xlarge": 0.3712,
    "m5.large": 0.096,
    "m5.xlarge": 0.192,
    "m5.2xlarge": 0.384,
    "m5.4xlarge": 0.768,
    "m5.8xlarge": 1.536,
    "m5.12xlarge": 2.304,
    "m5.16xlarge": 3.072,
    "m5.24xlarge": 4.608,
    "m5.metal": 4.608,
    "m5a.large": 0.086,
    "m5a.xlarge": 0.172,
    "m5a.2xlarge": 0.344,
    "m5a.4xlarge": 0.688,
    "m5a.8xlarge": 1.376,
    "m5a.12xlarge": 2.064,
    "m5a.16xlarge": 2.752,
    "m5a.24xlarge": 4.128,
    "m5ad.large": 0.103,
    "m5ad.xlarge": 0.206,
    "m5ad.2xlarge": 0.412,
    "m5ad.4xlarge": 0.824,
    "m5ad.12xlarge": 2.472,
    "m5ad.24xlarge": 4.944,
    "m5d.large": 0.113,
    "m5d.xlarge": 0.226,
    "m5d.2xlarge": 0.452,
    "m5d.4xlarge": 0.904,
    "m5d.8xlarge": 1.808,
    "m5d.12xlarge": 2.712,
    "m5d.16xlarge": 3.616,
    "m5d.24xlarge": 5.424,
    "m5d.metal": 5.424,
    "m4.large": 0.1,
    "m4.xlarge": 0.2,
    "m4.2xlarge": 0.4,
    "m4.4xlarge": 0.8,
    "m4.10xlarge": 2,
    "m4.16xlarge": 3.2,
    "c5.large": 0.085,
    "c5.xlarge": 0.17,
    "c5.2xlarge": 0.34,
    "c5.4xlarge": 0.68,
    "c5.9xlarge": 1.53,
    "c5.12xlarge": 2.04,
    "c5.18xlarge": 3.06,
    "c5.24xlarge": 4.08,
    "c5.metal": 4.08,
    "c5d.large": 0.096,
    "c5d.xlarge": 0.192,
    "c5d.2xlarge": 0.384,
    "c5d.4xlarge": 0.768,
    "c5d.9xlarge": 1.728,
    "c5d.18xlarge": 3.456,
    "c5n.large": 0.108,
    "c5n.xlarge": 0.216,
    "c5n.2xlarge": 0.432,
    "c5n.4xlarge": 0.864,
    "c5n.9xlarge": 1.944,
    "c5n.18xlarge": 3.888,
    "c5n.metal": 3.888,
    "c4.large": 0.1,
    "c4.xlarge": 0.199,
    "c4.2xlarge": 0.398,
    "c4.4xlarge": 0.796,
    "c4.8xlarge": 1.591,
    "p3.2xlarge": 3.06,
    "p3.8xlarge": 12.24,
    "p3.16xlarge": 24.48,
    "p3dn.24xlarge": 31.212,
    "p2.xlarge": 0.9,
    "p2.8xlarge": 7.2,
    "p2.16xlarge": 14.4,
    "g3.4xlarge": 1.14,
    "g3.8xlarge": 2.28,
    "g3.16xlarge": 4.56,
    "g3s.xlarge": 0.75,
    "x1.16xlarge": 6.669,
    "x1.32xlarge": 13.338,
    "x1e.xlarge": 0.834,
    "x1e.2xlarge": 1.668,
    "x1e.4xlarge": 3.336,
    "x1e.8xlarge": 6.672,
    "x1e.16xlarge": 13.344,
    "x1e.32xlarge": 26.688,
    "r5.large": 0.126,
    "r5.xlarge": 0.252,
    "r5.2xlarge": 0.504,
    "r5.4xlarge": 1.008,
    "r5.8xlarge": 2.016,
    "r5.12xlarge": 3.024,
    "r5.16xlarge": 4.032,
    "r5.24xlarge": 6.048,
    "r5.metal": 6.048,
    "r5a.large": 0.113,
    "r5a.xlarge": 0.226,
    "r5a.2xlarge": 0.452,
    "r5a.4xlarge": 0.904,
    "r5a.8xlarge": 1.808,
    "r5a.12xlarge": 2.712,
    "r5a.16xlarge": 3.616,
    "r5a.24xlarge": 5.424,
    "r5ad.large": 0.131,
    "r5ad.xlarge": 0.262,
    "r5ad.2xlarge": 0.524,
    "r5ad.4xlarge": 1.048,
    "r5ad.12xlarge": 3.144,
    "r5ad.24xlarge": 6.288,
    "r5d.large": 0.144,
    "r5d.xlarge": 0.288,
    "r5d.2xlarge": 0.576,
    "r5d.4xlarge": 1.152,
    "r5d.8xlarge": 2.304,
    "r5d.12xlarge": 3.456,
    "r5d.16xlarge": 4.608,
    "r5d.24xlarge": 6.912,
    "r5d.metal": 6.912,
    "r4.large": 0.133,
    "r4.xlarge": 0.266,
    "r4.2xlarge": 0.532,
    "r4.4xlarge": 1.064,
    "r4.8xlarge": 2.128,
    "r4.16xlarge": 4.256,
    "z1d.large": 0.186,
    "z1d.xlarge": 0.372,
    "z1d.2xlarge": 0.744,
    "z1d.3xlarge": 1.116,
    "z1d.6xlarge": 2.232,
    "z1d.12xlarge": 4.464,
    "z1d.metal": 4.464,
    "i3.large": 0.156,
    "i3.xlarge": 0.312,
    "i3.2xlarge": 0.624,
    "i3.4xlarge": 1.248,
    "i3.8xlarge": 2.496,
    "i3.16xlarge": 4.992,
    "i3.metal": 4.992,
    "i3en.large": 0.226,
    "i3en.xlarge": 0.452,
    "i3en.2xlarge": 0.904,
    "i3en.3xlarge": 1.356,
    "i3en.6xlarge": 2.712,
    "i3en.12xlarge": 5.424,
    "i3en.24xlarge": 10.848,
    "i3en.metal": 10.848,
    "h1.2xlarge": 0.468,
    "h1.4xlarge": 0.936,
    "h1.8xlarge": 1.872,
    "h1.16xlarge": 3.744,
    "d2.xlarge": 0.69,
    "d2.2xlarge": 1.38,
    "d2.4xlarge": 2.76,
    "d2.8xlarge": 5.52,
    "f1.2xlarge": 1.65,
    "f1.4xlarge": 3.3,
    "f1.16xlarge": 13.2
}

def get_credit(user_name):
    response = dynamodb_client.query(
        TableName=billing_table,
        ScanIndexForward=True,
        ProjectionExpression='credit_change',
        KeyConditionExpression='user_name = :uname',
        ExpressionAttributeValues={
            ':uname': {
                'S': user_name
            }
        }
    )
    credit = 0
    if 'Items' in response and len(response['Items']) > 0:
        for row in response['Items']:
            credit += float(row['credit_change']['N'])
    else:
        return _make_reply(_http_status(response), {
            'status': Status.NO_CREDIT_HISTORY,
            'error': 'No credit history for user: %s' % user_name
        })

    while 'LastEvaluatedKey' in response:
        response = dynamodb_client.query(
            TableName=billing_table,
            ScanIndexForward=True,
            ExclusiveStartKey=response['LastEvaluatedKey'],
            ProjectionExpression='credit_change',
            KeyConditionExpression='user_name = :uname',
            ExpressionAttributeValues={
                ':uname': {
                    'S': user_name
                }
            }
        )
        if 'Items' in response and len(response['Items']) > 0:
            for row in response['Items']:
                credit += float(row['credit_change']['N'])
    return _make_reply(_http_status(response), {
        'status': Status.OK,
        'credits': credit,
    })

def update_credit(user_name, credit_change):
    transaction = {
        'user_name': {
            'S': user_name
        },
        'timestamp': {
            'N': str(round(time.time() * 1000))
        },
        'credit_change': {
            'N': credit_change
        }
    }
    response = dynamodb_client.put_item(
        TableName=billing_table,
        Item=transaction
    )
    return _make_reply(_http_status(response), {
        'status': Status.OK
    })

def deduct_credit(user_name):
    # For expServer to invoke - it only has access to deduct credit.
    # No other configurable params - to avoid potential securty issue with juypter
    # To-do auth logic to make sure the caller is updating his credit only
    user_info = dynamodb_client.get_item(
        TableName=user_table,
        Key={
            'user_name': {
                'S': user_name
            }
        }
    )
    if 'Item' in user_info and 'S' in user_info['Item']['cfn_id']:
        cfn_id = user_info['Item']['cfn_id']['S']
    # else:
    #     return _make_reply(_http_status(user_info), {
    #         'status': Status.NO_RUNNING_CLUSTER,
    #         'error': 'No running cluster'
    #     })
    cfn_id = 'jerenetest2'
    cluster_info = get_cluster_info(cfn_id)
    if cluster_info['size'] == 0:
        return _make_reply(_http_status(user_info), {
            'status': Status.NO_RUNNING_CLUSTER,
            'error': 'No running cluster'
        })
    price = price_table[cluster_info['type']]
    credit_change = str(-1 * price_factor * price * cluster_info['size'] / 60)
    return update_credit(user_name, credit_change)

def get_cluster_info(cfn_id):
    response = cfn_client.describe_stacks(StackName=cfn_id)
    if 'Stack' not in response or len(response['Stacks']) == 0:
        return {
            'size': 0
        }
    stack = response['Stacks'][0]
    cluster_info = {}
    for param in stack['Parameters']:
        if param['ParameterKey'] == 'InstanceType':
            cluster_info['type'] = param['ParameterValue']
        elif param['ParameterKey'] == 'ClusterSize':
            cluster_info['size'] = int(param['ParameterValue'])
    return cluster_info

def lambda_handler(event, context):
    try:
        path = event['path']
        data = json.loads(event['body'])
        if path == '/billing/get':
            reply = get_credit(data['userName'])
        elif path == '/billing/update':
            reply = update_credit(data['userName'], data['creditChange'])
        elif path == '/billing/deduct':
            reply = deduct_credit(data['userName'])
        else:
            reply = _make_reply(400, "Invalid endpoint: %s" % path)
    except Exception as e:
        traceback.print_exc()
        reply = _make_reply(400, "Exception has occured: {}".format(e))
    return reply

def _make_reply(code, message):
    return {"statusCode": code, "body": json.dumps(message)}

def _http_status(resp):
    return resp["ResponseMetadata"]["HTTPStatusCode"]