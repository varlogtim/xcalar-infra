import json
def _make_reply(code, message):
    return {"statusCode": code, "body": json.dumps(message)}

def _http_status(resp):
    return resp["ResponseMetadata"]["HTTPStatusCode"]