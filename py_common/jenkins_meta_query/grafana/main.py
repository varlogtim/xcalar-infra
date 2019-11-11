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

sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
cfg = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO},
                        'JMQ_SERVICE_HOST': {'required': True},
                        'JMQ_SERVICE_PORT': {'required': True}})

from py_common.jenkins_meta_query.client import JMQClient
jmq_client = JMQClient(host = cfg.get('JMQ_SERVICE_HOST'),
                       port = cfg.get('JMQ_SERVICE_PORT'))

from flask import Flask, request, jsonify, json, abort
from flask_cors import CORS, cross_origin

# It's log, it's log... :)
logging.basicConfig(
                level=cfg.get("LOG_LEVEL"),
                format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

app = Flask(__name__)

cors = CORS(app)
app.config['CORS_HEADERS'] = 'Content-Type'

methods = ('GET', 'POST')

@app.route('/', methods=methods)
@cross_origin()
def test_connection():
    """
    / should return 200 ok. Used for "Test connection" on the datasource config page.
    """
    return "Connection check A-OK!"

def _parse_multi(multi):
    if '|' in multi:
        return [s.replace('\.', '.') for s in multi.strip('()').split('|')]
    return [multi.replace('\.', '.')]

@app.route('/search', methods=methods)
@cross_origin()
def find_metrics():
    """
    /search used by the find metric options on the query tab in panels and variables.
    """
    logger.info("start")
    req = request.get_json()
    logger.info("request: {}".format(request))
    logger.info("payload: {}".format(req))

    values = []
    target = req.get('target', None)
    logger.info("target: {}".format(target))
    if not target:
        return jsonify(values) # XXXrs - exception?

    if target == 'job_names':
        values.append('All Jobs') # Special :)
        values.extend(jmq_client.job_names())
    elif ':parameter_names' in target:
        job_name,rest = target.split(':')
        values = jmq_client.parameter_names(job_name=job_name.replace('\.', '.'))
    else:
        pass # XXXrs - exception?

    logger.debug("values: {}".format(values))
    return jsonify(values)

def _zulu_time_to_ts_ms(t_str):
    dt = datetime.datetime.strptime(t_str, "%Y-%m-%dT%H:%M:%S.%fZ")
    return int(dt.replace(tzinfo=pytz.utc).timestamp()*1000)

def _by_fail_pct(elem):
    return elem.get('fail_pct')

def _all_jobs_table(*, from_ms, to_ms):

    columns = [
        {"text":"Job Name", "type":"string"},
        {"text":"More", "type":"string"},
        {"text":"Pass Count", "type":"number"},
        {"text":"Pass Avg. Duration (s)", "type":"number"},
        {"text":"Fail Count", "type":"number"},
        {"text":"Fail Avg. Duration (s)", "type":"number"},
        {"text":"Abort Count", "type":"number"},
        {"text":"Fail %", "type":"number"}
    ]
    rows = []

    query = {'$and': [{'start_time_ms':{'$gt': from_ms}},
                      {'start_time_ms':{'$lt': to_ms}}]}

    for info in jmq_client.job_info():
        job_name = info.get('job_name')
        job_ref = ""
        try:
            job_ref = "<a href={}>here</a>".format(info.get('job_url'))
        except Exception as e:
            pass

        resp = jmq_client.find_builds(job_name=job_name,
                                      query=query,
                                      verbose=True)
        if not resp:
            logger.info("no builds found for job {}".format(job_name))
            continue

        pass_cnt = 0
        pass_total_duration_ms = 0
        pass_avg_duration_s = 0
        fail_cnt = 0
        fail_total_duration_ms = 0
        fail_avg_duration_s = 0
        abort_cnt = 0
        for bnum,item in resp.items():
            result = item.get('result', 'foo')
            if result == 'SUCCESS':
                pass_cnt += 1
                pass_total_duration_ms += item.get('duration_ms', 0)
            elif result == 'FAILURE':
                fail_cnt += 1
                fail_total_duration_ms += item.get('duration_ms', 0)
            elif result == 'ABORTED':
                abort_cnt += 1

        if pass_cnt:
            pass_avg_duration_s = int((pass_total_duration_ms/pass_cnt)/1000)

        if fail_cnt:
            fail_avg_duration_s = int((fail_total_duration_ms/fail_cnt)/1000)

        fail_pct = 0
        total = pass_cnt + fail_cnt
        if total:
            fail_pct = (fail_cnt*100)/(pass_cnt + fail_cnt)
        rows.append([job_name, job_ref,
                     pass_cnt, pass_avg_duration_s,
                     fail_cnt, fail_avg_duration_s,
                     abort_cnt, fail_pct])

    return [{"columns": columns, "rows": rows, "type" : "table"}]

def _map_result(result):
    """
    Map the result string to a numeric value to allow for threshold
    coloration on Grafana.  Can then be mapped back to string.
    """
    if result == 'SUCCESS':
        return 0
    if result == 'ABORTED':
        return 1
    # Presume failure
    return 2

def _job_table(*, job_name, parameter_names, from_ms, to_ms):


    rows = []
    columns = [
        {"text":"Build No.", "type":"string"},
        {"text":"More", "type":"string"},
        {"text":"Start Time", "type":"time"},
        {"text":"Duration (s)", "type":"time"},
        {"text":"Built On", "type": "string"},
        {"text":"Result", "type":"string"}
    ]
    for name in parameter_names:
        columns.append({"text": name, "type":"string"})

    query = {'$and': [{'start_time_ms':{'$gt': from_ms}},
                      {'start_time_ms':{'$lt': to_ms}}]}

    resp = jmq_client.find_builds(job_name = job_name,
                                  query = query,
                                  verbose = True)

    for bnum,item in resp.items():
        duration_s = int(item.get('duration_ms', 0)/1000)
        build_ref = ""
        try:
            build_ref = "<a href={}>here</a>".format(item.get('build_url'))
        except Exception as e:
            pass
        vals = [int(bnum),
                build_ref,
                item.get('start_time_ms', 0),
                duration_s,
                item.get('built_on', 'unknown'),
                _map_result(item.get('result'))]
        for name in parameter_names:
            vals.append(item.get('parameters', {}).get(name, "N/A"))
        rows.append(vals)
    return [{"columns": columns, "rows": rows, "type" : "table"}]

@app.route('/query', methods=methods)
@cross_origin(max_age=600)
def query_metrics():
    """
    /query should return metrics based on input.
    """
    logger.info("start")
    req = request.get_json()
    logger.info("request: {}".format(req))
    logger.info("request.args: {}".format(request.args))

    t_range = req.get('range', None)
    if not t_range:
        abort(404, Exception('range missing'))

    iso_from = t_range.get('from', None)
    if not iso_from:
        abort(404, Exception('range[from] missing'))
    from_ts_ms = _zulu_time_to_ts_ms(iso_from)
    logger.info("timestamp_from: {}".format(from_ts_ms))

    iso_to = t_range.get('to', None)
    if not iso_to:
        abort(404, Exception('range[to] missing'))
    to_ts_ms = _zulu_time_to_ts_ms(iso_to)
    logger.info("timestamp_to: {}".format(to_ts_ms))

    """
    # Not used
    freq_ms = req.get('intervalMs', None)
    if not freq_ms:
        abort(404, Exception('intervalMs missing'))
    logger.info("freq_ms: {}".format(freq_ms))
    """

    results = []
    request_type = None
    if len(req['targets']) > 1:
        abort(404, Exception('only single target allowed'))
    target = req['targets'][0]
    request_type = target.get('type', 'table')
    if request_type != 'table':
        abort(404, Exception('only table type supported'))
    fields = target.get('target', "").split(':')
    if not fields:
        abort(404, Exception('missing target (job name)'))
    job_name = fields[0]
    if job_name == "All Jobs":
        results = _all_jobs_table(from_ms=from_ts_ms, to_ms=to_ts_ms)
    else:
        parameter_names = []
        if len(fields) == 2:
            parameter_names = _parse_multi(fields[1])

        results = _job_table(job_name=job_name.replace('\.', '.'),
                             parameter_names=parameter_names,
                             from_ms=from_ts_ms, to_ms=to_ts_ms)

    logger.debug("table results: {}".format(results))
    return jsonify(results)

@app.route('/annotations', methods=methods)
@cross_origin(max_age=600)
def query_annotations():
    """
    /annotations should return annotations. :p
    """
    req = request.get_json()
    logger.info("headers: {}".format(request.headers))
    logger.info("req: {}".format(req))
    abort(404, Exception('not supported'))


@app.route('/panels', methods=methods)
@cross_origin()
def get_panel():
    """
    No documentation for /panels ?!?
    """
    req = request.args
    logger.info("headers: {}".format(request.headers))
    logger.info("req: {}".format(req))
    abort(404, Exception('not supported'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3003, debug= True)
