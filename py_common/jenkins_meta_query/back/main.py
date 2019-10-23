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
cfg = EnvConfiguration({'LOG_LEVEL': {'default': logging.DEBUG},
                        'JENKINS_HOST': {'required': True}})

from py_common.mongo import JenkinsMongoDB
from py_common.jenkins_aggregators import JenkinsAllJobIndex

from flask import Flask, request, jsonify, json, abort, make_response
from flask_cors import CORS, cross_origin

# It's log, it's log... :)
logging.basicConfig(
                level=cfg.get('LOG_LEVEL'),
                format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

app = Flask(__name__)
cors = CORS(app)
app.config['CORS_HEADERS'] = 'Content-Type'

jmdb = JenkinsMongoDB(jenkins_host=cfg.get('JENKINS_HOST'))
jdb = jmdb.jenkins_db()

methods=['GET']
@app.route('/', methods=methods)
@cross_origin()
def test_connection():
    """
    / should return 200 ok.
    """
    return "Connection check A-OK!"

@app.route('/jenkins_job_names', methods=methods)
@cross_origin()
def jenkins_job_names():
    names = [n for n in jdb.db.collection_names() if not n.endswith('_meta') and not n.startswith('_')]
    return make_response(jsonify({'job_names':names}))

def _get_upstream(*, job_name, build_number):
    upstream = []
    doc = jdb.db[job_name].find_one({'_id': build_number}, projection={'upstream':1})
    logger.debug(doc)
    if not doc:
        return None
    for item in doc.get('upstream', []):
        us_job = item.get('job_name', None)
        us_bnum = str(item.get('build_number', None))
        if not us_job or not us_bnum:
            continue
        upstream.append({'job_name': us_job,
                         'build_number': us_bnum,
                         'upstream': _get_upstream(job_name=us_job,
                                                    build_number=us_bnum)})
    if not len(upstream):
        return None
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

    return make_response(jsonify({'upstream':
                                  _get_upstream(job_name=job_name,
                                                build_number=build_number)}))

def _get_downstream(*, job_name, bnum, coll):
    key = "{}:{}".format(job_name, bnum)
    doc = coll.find({'_id': key})
    if not doc:
        return None
    pass

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

    alljob_idx = JenkinsAllJobIndex(jmdb=jmdb)
    downstream = alljob_idx.downstream_jobs(job_name=job_name, bnum=build_number)
    return make_response(jsonify(downstream))

@app.route('/jenkins_find_builds', methods=methods)
@cross_origin()
def jenkins_find_builds():
    job_name = request.args.get('job_name', None)
    if not job_name:
        abort(400, 'missing job_name')
    try:
        query = request.args.get('query', '{}')
        logger.debug('query: {}'.format(query))
        query = json.loads(query)
    except Exception as e:
        abort(400, str(e))

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
        for doc in jdb.db[job_name].find(query, **args):
            found[doc['_id']] = doc
        return make_response(jsonify(found))
    except Exception as e:
        abort(400, str(e))

@app.route('/jenkins_jobs_by_time', methods=methods)
@cross_origin()
def jenkins_jobs_by_time():
    now = time.time()
    start = request.args.get('start', 0)
    end = request.args.get('end', now)
    alljob_idx = JenkinsAllJobIndex(jmdb=jmdb)
    return make_response(jsonify(alljob_idx.jobs_by_time(start=int(start), end=int(end))))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=4000, debug=True)
