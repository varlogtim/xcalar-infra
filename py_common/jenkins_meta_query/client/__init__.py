#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import json
import logging
import os
import requests
import sys

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration

class JMQClient(object):

    ENV_PARAMS = {'JMQ_SERVICE_HOST': {'default': 'cvraman3.int.xcalar.com'},
                  'JMQ_SERVICE_PORT': {'default': '4000'} }

    def __init__(self, * , host, port):
        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(JMQClient.ENV_PARAMS)
        self.url_root="http://{}:{}".format(host, port)
        self.logger.debug(self.url_root)

    def _cmd(self, *, uri, params=None):
        url = "{}{}".format(self.url_root, uri)
        self.logger.debug("GET URL: {}".format(url))
        if params:
            self.logger.debug("GET PARAMS: {}".format(params))
            response = requests.get(url, params=params, verify=False) # XXXrs disable verify!
        else:
            response = requests.get(url, verify=False) # XXXrs disable verify!
        if response.status_code != 200:
            return None
        return response.json()

    def job_names(self):
        resp = self._cmd(uri = '/jenkins_job_names')
        return sorted(resp.get('job_names', []))

    def parameter_names(self, *, job_name):
        params = {'job_name': job_name}
        resp = self._cmd(uri = '/jenkins_job_parameters', params=params)
        return sorted(resp.get('parameter_names', []))

    def upstream(self, *, job_name, bnum):
        params = {'job_name': job_name, 'build_number': bnum}
        return self._cmd(uri = '/jenkins_upstream', params = params)

    def downstream(self, *, job_name, bnum):
        params = {'job_name': job_name, 'build_number': bnum}
        return self._cmd(uri = '/jenkins_downstream', params = params)

    def find_builds(self, *, job_name, query, verbose=False):
        params = {'job_name': job_name, 'query': json.dumps(query)}
        if not verbose:
            params['projection'] = json.dumps({'_id': 1})

        rtn = self._cmd(uri = '/jenkins_find_builds', params = params)
        if verbose:
            return rtn
        return rtn.keys()

if __name__ == '__main__':
    import pprint
    print("Compile check, A-OK!")

    client = JMQClient(host='cvraman3.int.xcalar.com', port=4000)
    print(pprint.pformat(client.downstream(job_name="DailyTests-Trunk", bnum=144)))
    print(pprint.pformat(client.parameter_names(job_name="DailyTests-Trunk")))