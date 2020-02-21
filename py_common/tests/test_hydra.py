#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.


from abc import ABC, abstractmethod

import argparse
import logging
import multiprocessing
import os
import random
import select
import shlex
import signal
import string
import subprocess
import sys
import time

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.hydra import LogScraperBase
from py_common.hydra import WatcherClassBase
from py_common.hydra import SubprocessWatcher
from py_common.hydra import ForkedProcessWatcher
from py_common.hydra import WatcherClassWatcher
from py_common.hydra import SDKMetricsWatcher
from py_common.hydra import Hydra

from xcalar.external.LegacyApi.XcalarApi import XcalarApi
from xcalar.external.client import Client

os.environ["XLR_PYSDK_VERIFY_SSL_CERT"] = "false"

# Configure logging
logging.basicConfig(level=logging.DEBUG,
                    format="'%(asctime)s - %(levelname)s - %(threadName)s - %(funcName)s - %(message)s",
                    handlers=[logging.StreamHandler(sys.stdout)])

# TEST CLASSES ==========

class TestLogScraperOne(LogScraperBase):

    def run(self, *, line):
        if 'Hello' in line:
            self.data_logger.message(msg="Scraper ONE saw Hello")


class TestLogScraperTwo(LogScraperBase):

    def run(self, *, line):
        if 'Goodbye' in line:
            self.data_logger.message(msg="Scraper TWO saw Goodbye")


class TestWatcherClassOne(WatcherClassBase):

    def run(self):
        random.seed()
        if random.randrange(2):
            word = "Hello"
        else:
            word = "Goodbye"
        self.data_logger.message(msg="Monitor ONE just saying {}".format(word))
        return None


class TestWatcherClassTwo(WatcherClassBase):

    def run(self):
        random.seed()
        if random.randrange(2):
            word = "Hello"
        else:
            word = "Goodbye"
        self.data_logger.message(msg="Monitor TWO just saying {}".format(word))
        return None


if __name__ == '__main__':

    logger = logging.getLogger(__name__)

    hydra = None
    def shutdownHydra(signum, frame):
        if hydra:
            hydra.do_shutdown = True

    signal.signal(signal.SIGINT, shutdownHydra)
    signal.signal(signal.SIGHUP, shutdownHydra)
    signal.signal(signal.SIGTERM, shutdownHydra)

    test_id = 'UnitTest'

    hydra = Hydra(test_id=test_id)
    scrapers = [TestLogScraperOne(test_id=test_id),
                TestLogScraperTwo(test_id=test_id)]

    for cmdline in ["echo Hello", "echo Goodbye", "sleep 30"]:
        sw = SubprocessWatcher(cmdline=cmdline,
                               scrapers=scrapers,
                               frequency=10)
        hydra.add(watcher=sw)

    def my_primary_function(*, loops):
        for i in range(loops):
            time.sleep(5)
            print("{}: XYZZY!".format(i))

    fpw = ForkedProcessWatcher(func=my_primary_function,
                               args={'loops':2},
                               scrapers=scrapers)
    hydra.add(watcher=fpw)

    sdkmm = SDKMetricsWatcher(host = "edison3.int.xcalar.com",
                              port = "8443",
                              user = "admin",
                              password = "admin",
                              test_id = test_id)
    wcw = WatcherClassWatcher(instance=sdkmm, frequency=5)
    hydra.add(watcher=wcw)

    wc1 = TestWatcherClassOne(test_id=test_id)
    wcw = WatcherClassWatcher(instance=wc1, frequency=1, scrapers=scrapers)
    hydra.add(watcher=wcw)

    wc2 = TestWatcherClassTwo(test_id=test_id)
    wcw = WatcherClassWatcher(instance=wc2, frequency=2, scrapers=scrapers)
    hydra.add(watcher=wcw)

    hydra.run()
