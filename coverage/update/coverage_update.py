#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import logging
import os
import time

from py_common.env_configuration import EnvConfiguration
from coverage.xd_unit_test_coverage import XDUnitTestArtifacts, XDUnitTestArtifactsData
from coverage.xce_func_test_coverage import XCEFuncTestArtifacts, XCEFuncTestArtifactsData

config = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO}})

# It's log, it's log... :)
logging.basicConfig(
                level=config.get('LOG_LEVEL'),
                format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

# Start the coverage data update threads...
xce_coverage_art = XCEFuncTestArtifacts()
xce_coverage_data = XCEFuncTestArtifactsData(artifacts = xce_coverage_art)
xce_coverage_data.start_update_thread()

xd_coverage_art = XDUnitTestArtifacts()
xd_coverage_data = XDUnitTestArtifactsData(artifacts = xd_coverage_art)
xd_coverage_data.start_update_thread()

while(1): # Spin!
    logger.info("running...")
    time.sleep(60)
