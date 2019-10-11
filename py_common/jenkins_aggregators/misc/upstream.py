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

sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
from py_common.mongo import JenkinsMongoDB

cfg = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO},
                        'JENKINS_HOST': {'default': 'jenkins.int.xcalar.com'}})

# It's log, it's log... :)
logging.basicConfig(level=cfg.get('LOG_LEVEL'),
                    format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                    handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

db = JenkinsMongoDB(jenkins_host = cfg.get('JENKINS_HOST')).byjob_db().db

for name in sorted(db.list_collection_names()):
    if "meta" in name:
        continue

    coll = db[name]
    upstream = {}
    for doc in coll.find({}):
        for info in doc.get('upstream', []):
            upstream[info['job_name']] = 1
    if upstream:
        print('{}: {}'.format(name, sorted(upstream.keys())))
