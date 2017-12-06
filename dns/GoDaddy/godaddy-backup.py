#!/usr/bin/env python

import os,sys
import json

from godaddypy import Client, Account

DOMAIN=os.environ['DOMAIN']
my_acct = Account(api_key=os.environ['GODADDY_KEY'], api_secret=os.environ['GODADDY_SECRET'])
client = Client(my_acct)
records = client.get_records(DOMAIN)
json.dump(records , sys.stdout)

