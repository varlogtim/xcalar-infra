import json
def _make_reply(code, message):
    return {
        'statusCode': code,
        'body': json.dumps(message),
        'headers': {
            'Access-Control-Allow-Origin': '*'
        }}

def _http_status(resp):
    return resp['ResponseMetadata']['HTTPStatusCode']