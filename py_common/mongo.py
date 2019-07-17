#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import logging
import subprocess
import time

from pymongo import MongoClient, WriteConcern, ReturnDocument
from pymongo.errors import ConnectionFailure
from pymongo.errors import DuplicateKeyError

from py_common.env_configuration import EnvConfiguration

# Defaults
mongo_db_user = 'root'
mongo_db_pass = 'Welcome1'
mongo_db_host = 'mongodb.service.consul'
mongo_db_port = '27017'
mongo_db_name = 'jenkins'

class MongoDB(object):

    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.cfg = EnvConfiguration({'MONGO_DB_HOST':  {'required': True,
                                                        'default': mongo_db_host},
                                     'MONGO_DB_PORT':  {'required': True,
                                                        'type': EnvConfiguration.NUMBER,
                                                        'default': mongo_db_port},
                                     'MONGO_DB_USER':  {'required': True,
                                                        'default': mongo_db_user},
                                     'MONGO_DB_PASS':  {'required': True,
                                                        'default': mongo_db_pass},
                                     'MONGO_DB_NAME':  {'required': True,
                                                        'default': mongo_db_name}
                                  })

        self.url = "mongodb://{}:{}@{}:{}/"\
                   .format(self.cfg.get('MONGO_DB_USER'),
                           self.cfg.get('MONGO_DB_PASS'),
                           self.cfg.get('MONGO_DB_HOST'),
                           self.cfg.get('MONGO_DB_PORT'))
        self.client = MongoClient(self.url)
        # Quick connectivity check...
        # The ismaster command is cheap and does not require auth.
        self.client.admin.command('ismaster')
        self.db = self.client[self.cfg.get('MONGO_DB_NAME')]
        self.logger.info(self.db)

    def collection(self, name):
        return self.db[name]

    @staticmethod
    def encode_key(key):
        return key.replace('.', '__dot__')

    @staticmethod
    def decode_key(key):
        return key.replace('__dot__', '.')

if __name__ == '__main__':
    print("Compile check A-OK!")

    mongo = MongoDB()
    coll = mongo.collection(name='test-collection')
    print(coll)

    """
    coll.remove({'_id': '123'})
    coll.insert({'_id': '123'})
    doc = coll.find_one_and_update({'_id': '123', 'meta':{'$exists': False}}, {'$inc': {'try_count': 1}}, return_document = ReturnDocument.AFTER)
    print(doc)
    doc = coll.find_one_and_update({'_id': '123', 'meta':{'$exists': False}}, {'$inc': {'try_count': 1}}, return_document = ReturnDocument.AFTER)
    print(doc)
    doc = coll.find_one_and_update({'_id': '123', 'meta':{'$exists': False}}, {'$unset': {'try_count': ''}, '$set': {'meta': {}}}, return_document = ReturnDocument.AFTER)
    print(doc)
    """

    for foo in range(10):
        doc = coll.find_one_and_update({'_id': 'fooset'}, {'$addToSet': {'members': foo}}, upsert=True)
    for foo in range(15):
        doc = coll.find_one_and_update({'_id': 'fooset'}, {'$addToSet': {'members': foo}}, upsert=True)
