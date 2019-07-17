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

from py_common.env_configuration import EnvConfiguration
from coverage.xd_unit_test_coverage import XDUnitTestArtifacts, XDUnitTestArtifactsData
from coverage.xce_func_test_coverage import XCEFuncTestArtifacts, XCEFuncTestArtifactsData


ENV_PARAMS = {} # XXXrs placeholder
config = EnvConfiguration(ENV_PARAMS)

from flask import Flask, request, jsonify, json, abort
from flask_cors import CORS, cross_origin

# It's log, it's log... :)
logging.basicConfig(
                level=logging.INFO,
                format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

app = Flask(__name__)

cors = CORS(app)
app.config['CORS_HEADERS'] = 'Content-Type'

methods = ('GET', 'POST')

xd_coverage_art = XDUnitTestArtifacts()
xd_coverage_data = XDUnitTestArtifactsData(artifacts = xd_coverage_art)

xce_coverage_art = XCEFuncTestArtifacts()
xce_coverage_data = XCEFuncTestArtifactsData(artifacts = xce_coverage_art)

if not os.environ.get("WERKZEUG_RUN_MAIN"):
    # Only do this on initial load or we'll end up with
    # multiple overlapping update threads (at least in debug).
    xce_coverage_data.start_update_thread()
    xd_coverage_data.start_update_thread()

@app.route('/', methods=methods)
@cross_origin()
def test_connection():
    """
    / should return 200 ok. Used for "Test connection" on the datasource config page.
    """
    return "Connection check A-OK!"

def _parse_multi(multi):
    if '|' in multi:
        return [s.replace('\.', '.').replace('\/', '/') for s in multi.strip('()').split('|')]
    return [multi.replace('\.', '.').replace('\/', '/')]

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

    names = []
    target = req.get('target', None)
    logger.info("target: {}".format(target))
    if not target:
        return jsonify(names) # XXXrs - exception?

    if target == 'xd_versions':
        names = xd_coverage_data.xd_versions()

    elif target == 'xce_versions':
        names = xce_coverage_data.xce_versions()

    # <xd_vers>:xdbuilds
    elif ':xdbuilds' in target:
        # Build list will be all builds available matching the XD version(s).
        xd_vers,rest = target.split(':')
        names = xd_coverage_data.builds(xd_versions=_parse_multi(xd_vers),
                                        reverse=True)
    # <build>:xdfiles
    elif ':xdfiles' in target:
        # xdfiles list will be all files for which we track coverage (based on
        # files tracked for build).
        bnum1,rest = target.split(':')
        names = xd_coverage_data.filenames(bnum=bnum1)

    # <xce_vers>:xcebuilds
    elif ':xcebuilds' in target:
        # Build list will be all builds available matching the XCE version(s).
        xce_vers,rest = target.split(':')
        names = xce_coverage_data.builds(xce_versions=_parse_multi(xce_vers),
                                         reverse=True)
    # <build>:xcefiles
    elif ':xcefiles' in target:
        # xcefiles list will be all files for which we track coverage (based on
        # files tracked for build).
        bnum1,rest = target.split(':')
        names = xce_coverage_data.filenames(bnum=bnum1)

    else:
        pass # XXXrs - exception?

    logger.debug("names: {}".format(names))
    return jsonify(names)

def _xd_results(*, xd_vers, first_bnum, filenames, ts):
    logger.info("xd_vers: {} first_bnum: {} filenames: {}"
                .format(xd_vers, first_bnum, filenames))
    builds = xd_coverage_data.builds(xd_versions=_parse_multi(xd_vers),
                                     first_bnum=first_bnum,
                                     reverse=False)

    results = []
    for bnum in builds:
        for filename in filenames:
            results.append({'target': '{}'.format(bnum),
                            'datapoints': [[xd_coverage_data.coverage(
                                                bnum=bnum, filename=filename), ts]] })
    logger.debug("results: {}".format(results))
    return results

def _xce_results(*, xce_vers, first_bnum, filenames, ts):
    logger.info("xce_vers: {} first_bnum: {}".format(xce_vers, first_bnum))
    builds = xce_coverage_data.builds(xce_versions=_parse_multi(xce_vers),
                                      first_bnum=first_bnum,
                                      reverse=False)
    logger.info("builds: {}".format(builds))

    results = []
    for bnum in builds:
        for filename in filenames:
            results.append({'target': '{}'.format(bnum),
                            'datapoints': [[xce_coverage_data.coverage(
                                                bnum=bnum, filename=filename), ts]] })
    logger.debug("results: {}".format(results))
    return results

def _timeserie_results(*, target, request_ts_ms):
    """
    Target name format:
        <xd_versions>:<first_bnum>:<filename>:xd
        or
        <xce_versions>:<first_bnum>:<filename>:xce
    """

    logger.info("start")

    t_name = target.get('target', None)
    logger.info("t_name: {}".format(t_name))
    if not t_name:
        err = 'target has no name: {}'.format(target)
        logger.exception(err)
        abort(404, ValueError(err))
    try:
        vers,first_bnum,filename,mode = t_name.split(':')
    except Exception as e:
        err = 'incomprehensible target name: {}'.format(t_name)
        logger.exception(err)
        abort(404, ValueError(err))

    """
    first_bnum is the first build to return.
    Want all builds of same version since then.
    """
    if mode == "xd":
        return _xd_results(xd_vers = vers,
                           first_bnum = first_bnum,
                           filenames = _parse_multi(filename),
                           ts = request_ts_ms)
    elif mode == "xce":
        return _xce_results(xce_vers = vers,
                            first_bnum = first_bnum,
                            filenames = _parse_multi(filename),
                            ts = request_ts_ms)

    err = 'unknown mode: {}'.format(mode)
    logger.exception(err)
    abort(404, ValueError(err))


def _zulu_time_to_ts_ms(t_str):
    dt = datetime.datetime.strptime(t_str, "%Y-%m-%dT%H:%M:%S.%fZ")
    return int(dt.replace(tzinfo=pytz.utc).timestamp()*1000)


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

    # XXXrs - mostly boilerplate of little value...
    t_range = req.get('range', None)
    if not t_range:
        abort(404, Exception('range missing'))

    # XXXrs - ...except this. Use this time force all results into the present.
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

    freq_ms = req.get('intervalMs', None)
    if not freq_ms:
        abort(404, Exception('intervalMs missing'))
    logger.info("freq_ms: {}".format(freq_ms))

    results = []
    request_type = None
    for target in req['targets']:
        if not request_type:
            request_type = target.get('type', 'timeserie')
        if request_type != 'timeserie':
            abort(404, Exception('only timeserie type supported'))

        # Return results in timeserie format, but we're not actually
        # using a time-series.  We force all results into the board's
        # present time-frame so that nothing is filtered out.
        ts_results = _timeserie_results(target = target,
                                        request_ts_ms = from_ts_ms)
        results.extend(ts_results)

    logger.debug("timeserie results: {}".format(results))
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
    app.run(host='0.0.0.0', port=3004, debug= True)
