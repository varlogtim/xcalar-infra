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
import time

from py_common.env_configuration import EnvConfiguration
config = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO}})

from sql_tpch.sql_tpch import SqlTpchStatsArtifacts, SqlTpchStatsArtifactsData

# It's log, it's log... :)
logging.basicConfig(
                level=config.get('LOG_LEVEL'),
                format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

# Start the sql TPC-H data update threads...
sql_tpch_art = SqlTpchStatsArtifacts()
sql_tpch_data = SqlTpchStatsArtifactsData(artifacts = sql_tpch_art)
sql_tpch_data.start_update_thread()

while(1): # Spin!
    logger.info("running...")
    time.sleep(60)
