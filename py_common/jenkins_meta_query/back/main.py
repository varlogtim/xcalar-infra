#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import datetime
import logging
import os
import pytz
import random
import re
import statistics
import sys
import time

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
config = EnvConfiguration({'LOG_LEVEL': {'default': logging.DEBUG}})

from py_common.mongo import MongoDB

from flask import Flask, request, jsonify, json, abort, make_response
from flask_cors import CORS, cross_origin

# It's log, it's log... :)
logging.basicConfig(
                level=config.get('LOG_LEVEL'),
                format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

app = Flask(__name__)
cors = CORS(app)
app.config['CORS_HEADERS'] = 'Content-Type'

mongo = MongoDB()

methods=['GET']
@app.route('/', methods=methods)
@cross_origin()
def test_connection():
    """
    / should return 200 ok.
    """
    return "Connection check A-OK!"


def _upstream_from(*, job_name, build_number):

    upstream = []
    doc = mongo.db[job_name].find_one({'_id': build_number}, projection={'upstream':1})
    logger.debug(doc)
    if not doc:
        return
    for item in doc.get('upstream', []):
        us_job = item.get('job_name', None)
        us_bnum = str(item.get('build_number', None))
        if not us_job or not us_bnum:
            continue
        upstream.append({'job_name': us_job,
                         'build_number': us_bnum,
                         'upstream': _upstream_from(job_name=us_job,
                                                    build_number=us_bnum)})
    return upstream

@app.route('/jenkins_upstream', methods=methods)
@cross_origin()
def jenkins_upstream():
    """
    """
    job_name = request.args.get('job_name', None)
    if not job_name:
        abort(400, 'missing downstream job_name')

    build_number = request.args.get('build_number', None)
    if not build_number:
        abort(400, 'missing downstream build_number')

    return make_response(jsonify({'upstream_jobs':
                                    _upstream_from(job_name=job_name,
                                                   build_number=build_number)}))


def _downstream_from(*, job_name, build_number, collection_names):

    downstream = []
    query = {'upstream.job_name': job_name, 'upstream.build_number': int(build_number)}
    logger.debug(query)
    for name in collection_names:
        logger.debug("name: {}".format(name))
        for doc in mongo.db[name].find(query, projection={'_id': 1}):
            logger.debug("doc: {}".format(doc))
            ds_job = name
            ds_bnum = doc['_id']
            downstream.append({'job_name':ds_job,
                               'build_number':ds_bnum,
                               'downstream':_downstream_from(job_name=ds_job,
                                                             build_number=ds_bnum,
                                                             collection_names=collection_names)})
    return downstream


@app.route('/jenkins_downstream', methods=methods)
@cross_origin()
def jenkins_downstream():
    """
    """
    job_name = request.args.get('job_name', None)
    if not job_name:
        abort(400, 'missing upstream job_name')

    build_number = request.args.get('build_number', None)
    if not build_number:
        abort(400, 'missing upstream build_number')


    downstream = {'downstream_jobs':
                    _downstream_from(job_name=job_name,
                                     build_number=build_number,
                                     collection_names=mongo.job_collections())}
    return make_response(jsonify(downstream))


@app.route('/jenkins_find', methods=methods)
@cross_origin()
def jenkins_find():
    job_name = request.args.get('job_name', None)
    if not job_name:
        abort(400, 'missing job_name')
    try:
        query = request.args.get('query', '{}')
        logger.debug('query: {}'.format(query))
        query = json.loads(query)
    except Exception as e:
        abort(400, str(e))

    if not query:
        abort(400, 'missing query')

    try:
        proj = request.args.get('projection', '{}')
        logger.debug('proj: {}'.format(proj))
        proj = json.loads(proj)
    except Exception as e:
        abort(400, str(e))

    try:
        found = {}
        args = {}
        if proj:
            args['projection'] = proj
        for doc in mongo.db[job_name].find(query, **args):
            found[doc['_id']] = doc
        return make_response(jsonify(found))
    except Exception as e:
        abort(400, str(e))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=4000, debug=True)
