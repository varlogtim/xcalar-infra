#!/usr/bin/env python3
import os
import sys
import json
import requests
# Insert discover into our python path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'discover'))

from discover_schema import DiscoverSchemaStack

# Given only our stack name
STACK_NAME = os.getenv('STACK_NAME', f'DiscoverSchemaStack')
STAGE = os.getenv('STAGE', 'Prod')
REGION = os.getenv('AWS_DEFAULT_REGION', 'us-west-2')

API_ENDPOINT = os.getenv('API_ENDPOINT', None)
if not API_ENDPOINT:
    # Given only our stack name, find the RestApi end point
    stack = DiscoverSchemaStack(STACK_NAME)
    rest_api = stack.get_stack_resource('ServerlessRestApi')['PhysicalResourceId']
    API_ENDPOINT = f'https://{rest_api}.execute-api.{REGION}.amazonaws.com/{STAGE}/discover/'

params = {'bucket': 'xcfield', 'key': 'instantdatamart/csv/readings.csv', 'format': 'schema'}

r = requests.get(url=API_ENDPOINT, params=params)

print(r.json())
