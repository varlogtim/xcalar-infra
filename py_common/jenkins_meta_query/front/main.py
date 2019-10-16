#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import logging
import os
import sys
import requests
import time

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
cfg = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO},
                        'BACKEND_HOST': {'required': True},
                        'BACKEND_PORT': {'required': True}})
    
from flask import Flask, request
from flask import render_template, make_response, jsonify
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

methods=['GET']
@app.route('/', methods=methods)
@cross_origin()
def test_connection():
    """
    / should return 200 ok.
    """
    return "Connection check A-OK!"

# Template expects passed parameter
@app.route('/jenkins_jobs_by_time', methods=methods)
@cross_origin()
def jenkins_jobs_by_time():
    now = int(time.time())
    start = request.args.get('start', 0)
    end = request.args.get('end', now)
    back_url = "http://{}:{}/jenkins_jobs_by_time?start={}&end={}"\
               .format(cfg.get('BACKEND_HOST'), cfg.get('BACKEND_PORT'), start, end)
    response = requests.get(back_url, verify=False) # XXXrs disable verify!
    jobs = response.json()
    logger.info("jobs {}".format(jobs))
    logger.info("jobs length: {}".format(len(jobs)))
    return render_template("jobs_table.html", jobs=jobs['jobs'])

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=4001, debug=True)
