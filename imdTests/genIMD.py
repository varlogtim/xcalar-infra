import argparse
import json
import hashlib
import time
import timeit
import sys
import tarfile
from tarfile import TarInfo
import os
import io
import subprocess
import signal
from datetime import datetime

### Start Xcalar Code ###
#Xcalar imports. For more information, refer to discourse.xcalar.com
from xcalar.external.LegacyApi.XcalarApi import XcalarApi
from xcalar.external.LegacyApi.Session import Session
from xcalar.external.LegacyApi.Retina import Retina

from IMDUtil import IMDOps
from prepareEnv import TestEnvironment

class DataGenerator(object):
    def __init__(self, args):
        self.mgmtdUrl="http://%s:9090/thrift/service/XcalarApiService/" % args.xcalar.rstrip()
        self.xcApi = XcalarApi(self.mgmtdUrl)
        self.username = args.user
        self.userIdUnique = int(hashlib.md5(self.username.encode("UTF-8")).hexdigest()[:5], 16) + 4000000
        try:
            self.session = Session(self.xcApi, self.username, self.username, 
                    self.userIdUnique, True, sessionName=args.session)
        except Exception as e:
            print("Could not set session for %s" % (self.username))
            raise e
        self.xcApi.setSession(self.session)
        self.retina = Retina(self.xcApi)

        if args.env == 'local':
            self.importTargetName = "Default Shared Root"
            self.exportTargetName = "Default"
            self.exportUrl = args.exportUrl
            self.imd = True
        #TODO: Need to test this once Bug 12769 is resolved
        elif args.env == 's3':
            self.importTargetName = "s3DatagenImport"
            self.exportTargetName = "s3DatagenExport"
            self.exportUrl = args.exportUrl
            self.imd = True
        #TODO: Need to test this once Bug 12769 is resolved
        elif args.env == 'postgresqldb':
            self.exportTargetName = 'pgDbDatagenExport'
            self.imd = False

        self.xcalar = args.xcalar
        self.retName = args.cube
        self.numBaseRows = args.numBaseRows
        self.numUpdateRows = args.numUpdateRows
        self.numUpdates = args.numUpdates
        self.bases = args.bases
        self.updates = args.updates
        self.updateSleep = args.updateSleep
        self.numThreads = args.numThreads

        self.schema = self.__getSchema("{}.json".format(self.retName))
        testEnv = TestEnvironment(self.xcApi, self.exportUrl, args.env)
        testEnv.run()
        self.imdOps = IMDOps(self.xcApi)

    def __getSchema(self, schemaName):
        schema = None
        with open("schemas/" + schemaName) as f:
            return json.load(f)

    def __genData(self):
        params = ['numRows', 'exportTargetName', 'fileName']
        dfParams = []
        for param in params:
            dfParams.append(
                    {
                        "paramName":param,
                        "paramValue":str(getattr(self, param))
                    }
                )
        print("Generating data for tables with", self.retName)
        self.retina.execute(self.retName, dfParams)
        print("Data generation with {}, done!".format(self.retName))

    def __doIMD(self):
        for tab in self.schema:
            print(self.exportUrl, tab, self.fileName)
            path = os.path.join(self.exportUrl, tab, self.fileName)
            self.schema[tab]["path"] = path
            self.schema[tab]["targetName"] = self.importTargetName
        if self.fileName == "base":
            self.imdOps.createPubTables(self.schema)
        else:
            self.imdOps.applyUpdates(self.schema)

    def main(self):
        print("====================================")
        print(datetime.now().strftime("%d %b %Y %H:%M:%S"))
        print("====================================")
        if self.bases:
            self.fileName = "base"
            self.numRows = self.numBaseRows
            self.__genData()
            if self.imd:
                self.__doIMD()
        
        #trigger the slow changing and cubes asyncly
        programPath = os.path.abspath("triggerDimsCubes.py")
        datasetPath = "/freenas/imdtests/"
        
        triggerCubeCmd = "python3 {} -x {} -u {} -i \"{}\" -p {} -c {}".format(programPath, self.xcalar, self.username, "Default Shared Root", datasetPath, self.retName)
        pr1 = subprocess.Popen(triggerCubeCmd,
                           stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE,
                           shell=True)
        queryCubeProgramPath = os.path.abspath("queryCube.py")
        if self.retName == 'ecommTables':
            cubeName = 'ecommcube'
        elif self.retName == 'transacTables':
            cubeName = 'transcube'
        else:
            raise ValueError("Invalid data generation retina")
        queryCubeCmd = "python3 {} -x {} -u {} -c {} --numThreads {}".format(
                        queryCubeProgramPath, self.xcalar, self.username, 
                        cubeName, self.numThreads)
        pr2 = subprocess.Popen(queryCubeCmd,
                           stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE,
                           shell=True)

        if self.updates:
            while pr1.poll() is None and pr2.poll() is None and self.numUpdates > 0:
                self.fileName = "updates/{}".format(int(time.time()))
                self.numRows = self.numUpdateRows
                self.__genData()
                if self.imd:
                    self.__doIMD()
                self.numUpdates -= 1
                time.sleep(self.updateSleep)
        if pr1.poll():
            out, err = pr1.communicate()
            print ("{}".format(out.strip().decode('utf-8')))
            if pr1.returncode != 0:
                raise ValueError(err)
        if pr2.poll():
            out, err = pr2.communicate()
            print ("{}".format(out.strip().decode('utf-8')))
            if pr2.returncode != 0:
                raise ValueError(err)
        if pr1.poll() is None:
            os.killpg(os.getpgid(pr1.pid), signal.SIGTERM)
        if pr2.poll() is None:
            os.killpg(os.getpgid(pr2.pid), signal.SIGTERM)

if __name__ == '__main__':
    argParser = argparse.ArgumentParser(description="Prime Xcalar cluster with imd tables and cubes generation and updates running")
    argParser.add_argument('--xcalar', '-x', help="Ip address/hostname of mgmtd instance", required=True, default="localhost")
    argParser.add_argument('--user', '-u', help="Xcalar User", required=True, default="admin")
    argParser.add_argument('--session', '-s', help="Name of session", required=True)
    argParser.add_argument('--numBaseRows', help="Number of rows to generate", required=False, default=2000, type=int)
    argParser.add_argument('--exportUrl', help="Where to export the data", required=True, default="/mnt/xcalar/export/")
    argParser.add_argument('--cube', '-c', help="what cube data to generate", 
                        choices=['ecommTables', 'transacTables'], required=True)
    argParser.add_argument('--env', help="environment to import and export files", 
                        choices=['local', 's3', 'postgresqldb'], required=True)
    argParser.add_argument('--bases', help="generate base table", action='store_true')
    argParser.add_argument('--updates', help="generate updates", action='store_true')
    argParser.add_argument('--numUpdates', help="number of updates, (specify negative value to run infinitely)", 
                        required=False, default=1, type=int)
    argParser.add_argument('--numUpdateRows', help="update row count", required=False, default=20, type=int)
    argParser.add_argument('--updateSleep', help="sleep in seconds for update loop", required=False, default=1, type=int)
    argParser.add_argument('--numThreads', help="number of threads to run and do concurrent selects on cube", 
                    required=False, default=8, type=int)

    
    args = argParser.parse_args()
    if not hasattr(args, 'exportUrl'):
        args.exportUrl = None

    if not args.bases and not args.updates:
            print ("neither --base nor --updates are defined\n")
            print ("one of them is required")
            sys.exit(1)
    
    if args.numUpdateRows <= 0 or args.numBaseRows <= 0:
        print("numUpdateRows and numBaseRows should be positive numbers\n")
        sys.exit(1)

    if args.numUpdates < 0:
        args.numUpdates = float('Inf')

    dataGenerator = DataGenerator(args)
    dataGenerator.main()
