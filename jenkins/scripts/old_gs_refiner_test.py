#!/usr/bin/env python

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.
#

import argparse
import logging
import os
import sys
import time

from xcalar.external.LegacyApi.XcalarApi import XcalarApi, XcalarApiStatusException
from xcalar.external.client import Client

class OGSRTFail(Exception):
    pass

# XXXrs - MAGIC STRINGS :(
WORKBOOK_PATH = "/netstore/goldman-info/valueasset-compute.conc.xlrwb.tar.gz"
WORKBOOK_NAME = "valueasset-compute"
DATA_TARGET_NAME = "gs"
DATAFLOW_NAME = "Accrual Enricher"
DATAFLOW_PARAMS = {"asOfCutOffDate" : "1520049600000000",
                   "currentBusinessDate" : "1527825600000000",
                   "fromDate" : "1527825600000000",
                   "infinityTimestamp" : "253370764800000000",
                   "toDate" : "1527825600000000"}

os.environ["XLR_PYSDK_VERIFY_SSL_CERT"] = "false"

class OldGSRefinerTest(object):

    def __init__(self, *, host, port, user, password,
                          workbook_path=WORKBOOK_PATH,
                          workbook_name=WORKBOOK_NAME,
                          data_target_name=DATA_TARGET_NAME):
        self.logger = logging.getLogger(__name__)
        self.logger.info("STARTING")
        self.xcalar_url = "https://{}:{}".format(host, port)
        self.client_secrets = {'xiusername': user, 'xipassword': password}
        self.xcalar_api = XcalarApi(url=self.xcalar_url, client_secrets=self.client_secrets)
        self.client = Client(url=self.xcalar_url, client_secrets=self.client_secrets)

        self.workbook_path = workbook_path
        self.workbook_name = workbook_name

        try:
            workbook = self.client.get_workbook(workbook_name=self.workbook_name)
            self.logger.info("got pre-existing workbook")
        except:
            with open(self.workbook_path, 'rb') as wbfd:
                self.logger.info("uploading workbook")
                workbook = self.client.upload_workbook(
                                workbook_name=self.workbook_name,
                                workbook_content=wbfd.read())
        self.workbook = workbook
        self.xcalar_api.setSession(workbook)

        self.data_target_name = data_target_name
        try:
            data_target = self.client.get_data_target(target_name=self.data_target_name)
            self.logger.info("got pre-existing data target")
        except:
            self.logger.info("adding data target")
            data_target = self.client.add_data_target(
                                target_name=self.data_target_name,
                                target_type_id="shared",
                                params = {"mountpoint":"/netstore/datasets/goldman-info/gs_csv"})
        self.data_target = data_target

        self.logger.info("activating workbook")
        self.session = self.workbook.activate()

        self.dataflow_names = self.workbook.list_dataflows()
        self.logger.info("dataflow names in workbook: {}".format(self.dataflow_names))


    def _execute_df(self, *, job_name, dataflow_name, dataflow_params):
        self.logger.info("STARTING")

        self.logger.info("getting dataflow: {}".format(dataflow_name))
        dataflow = self.workbook.get_dataflow(dataflow_name, params=dataflow_params)

        self.logger.info("executing job_name: {}".format(job_name))
        result = self.session.execute_dataflow(dataflow, query_name=job_name, optimized=True)


    def start_jobs(self, *, batch, instances):
        self.logger.info("STARTING")

        job_pfx = "Xcalar_{}".format(int(time.time()))
        for instance in range(instances):
            job_name = "{}_batch{}_instance{}".format(job_pfx, batch, instance)
            self._execute_df(job_name = job_name,
                             dataflow_name = DATAFLOW_NAME,
                             dataflow_params = DATAFLOW_PARAMS)
        return job_pfx


    def wait_for_jobs(self, *, job_name_pfx):
        self.logger.info("STARTING")
        q_pending=True
        while q_pending is True:
            q_pending = False
            q_num_done=0
            q_num_pending=0
            qs = self.xcalar_api.listQueries("{}*".format(job_name_pfx))
            for q in qs.queries:
                if job_name_pfx not in q.name:
                    self.logger.error("listed job/query {} does not contain prefix {}"
                                      .format(q.name, job_name_prefix))
                    continue

                if q.state == 'qrFinished' or q.state == 'qrCancelled':
                    self.logger.info("job {} is DONE".format(q.name))
                    q_num_done = q_num_done + 1

                elif q.state == 'qrError':
                    raise OGSRTFail("job/query {} ERROR".format(q.name))

                else:
                    self.logger.info("job {} is NOT done {}".format(q.name, q.state))
                    q_num_pending = q_num_pending + 1
                    q_pending = True
            self.logger.info("job status: {} done {} pending\n"
                             .format(q_num_done, q_num_pending))
            time.sleep(10)


    def cleanup_jobs(self, *, job_name_pfx):
        self.logger.info("STARTING")
        qs = self.xcalar_api.listQueries("{}*".format(job_name_pfx))
        q_pending = True
        while q_pending:
            q_pending = False
            for q in qs.queries:
                if job_name_pfx not in q.name:
                    self.logger.error("listed job/query {} does not contain prefix {}"
                                      .format(q.name, job_name_prefix))
                    continue
                if q.state == 'qrProcessing':
                    # Shouldn't get here :/
                    self.logger.info("cancel job {}".format(q.name))
                    self.xcalar_api.cancelQuery(q.name)
                    q_pending = True
                else:
                    self.logger.info("deleting job {}".format(q.name))
                    self.xcalar_api.deleteQuery(q.name)


    def run(self, *, batches, instances):
        for batch in range(batches):
            job_name_pfx = self.start_jobs(batch=batch, instances=instances)
            self.wait_for_jobs(job_name_pfx=job_name_pfx)
            self.cleanup_jobs(job_name_pfx=job_name_pfx)


    def cleanup(self):
        self.logger.info("STARTING")
        self.session.destroy()
        self.xcalar_api.setSession(None)
        self.session = None
        self.sdk_session = None
        self.xcalar_api = None


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger()
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", help="Xcalar hostname", required=True)
    parser.add_argument("--port", help="Xcalar API port", required=True)
    parser.add_argument("--user", help="User to run as", required=True)
    parser.add_argument("--pass", dest='password', help="User's password", required=True)
    parser.add_argument("--batches", help="Number of Batches", type=int, required=True)
    parser.add_argument("--instances", help="Number of parallel instances per batch", type=int, required=True)
    args = parser.parse_args()

    failed = False
    test = None
    start_time = None
    end_time = None

    try:
        test = OldGSRefinerTest(host     = args.host,
                                port     = args.port,
                                user     = args.user,
                                password = args.password)

    except:
        logger.exception("FAIL: Unexpected Exception during initialization")
        failed = True

    if not failed:
        try:
            start_time = int(time.time())
            logger.info("Test start time: {}".format(start_time))
            test.run(batches   = args.batches,
                     instances = args.instances)
            end_time = int(time.time())
            logger.info("Test end time: {}".format(end_time))

        except OGSRTFail:
            logger.exception("FAIL: Job/Query Error")
            failed = True

        except:
            logger.exception("FAIL: Unexpected Exception")
            failed = True

    if test:
        try:
            test.cleanup()
        except Exception as e:
            # Cleanup failures don't fail the test.
            logger.warn("Unexpected Exception during cleanup", exc_info=True)

    if not failed:
        if start_time is not None and end_time is not None:
            logger.info("Test Duration: {} seconds".format(end_time - start_time))
        else:
            logger.error("Timestamp(s) missing, can not calculate duration")
        logger.info("SUCCESS")

    sys.exit(failed)
