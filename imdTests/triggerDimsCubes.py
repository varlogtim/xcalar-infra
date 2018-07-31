import hashlib
from xcalar.external.LegacyApi.XcalarApi import XcalarApi, XcalarApiStatusException
from xcalar.external.LegacyApi.Session import Session
from xcalar.external.LegacyApi.WorkItem import WorkItem, WorkItemListXdfs
from xcalar.external.LegacyApi.ResultSet import ResultSet
from xcalar.external.LegacyApi.Retina import *
from xcalar.external.LegacyApi.Operators import *
from xcalar.compute.coretypes.Status.ttypes import StatusT
import xcalar.external.LegacyApi.Udf as XcUdf

from datetime import datetime, timedelta
from time import sleep
import timeit
import tempfile
import tarfile
from tarfile import TarInfo
import os
import io
import argparse

##These are the slow changing dimension tables and cubes
##Slow changing dimesions will update very less frequently
cubesArrays = {
    "ecommTables": [
        {
            "publishedTableName": "product_category",
            "dataflowName": "product_categ_dim",
            "intervalInMins": 10,
            "enable": True,
        },
        {
            "publishedTableName": "product_sub_category",
            "dataflowName": "product_sub_categ_dim",
            "intervalInMins": 15,
            "enable": True,
        },
        {
            "publishedTableName": "product",
            "dataflowName": "product_dim",
            "intervalInMins": 12,
            "enable": True
        },
        { 
            "publishedTableName": "ecommcube",
            "dataflowName": "ecommcube",
            "intervalInMins": 5,
            "enable": True
        }
    ],
    "transacTables": [
        {
            "publishedTableName": "company",
            "dataflowName": "company_dim",
            "intervalInMins": 20,
            "enable": True
        },
        {
            "publishedTableName": "exch_countrycode",
            "dataflowName": "exch_countrycode_dim",
            "intervalInMins": 25,
            "enable": True
        },
        {
            "publishedTableName": "transcube",
            "dataflowName": "transcube",
            "intervalInMins": 2,
            "enable": True
        }
    ]
}

def initialise(args):
    global op
    global retina
    global xcUdf
    global params
    global availableRetinas
    global cubeArray
    global path
    global workbook

    mgmtdUrl="http://%s:9090/thrift/service/XcalarApiService/" % args.xcalar.rstrip()
    xcalarApi = XcalarApi(mgmtdUrl)
    username = args.user
    userIdUnique = int(hashlib.md5(username.encode("UTF-8")).hexdigest()[:5], 16) + 4000000
    try:
        workbook = Session(xcalarApi, username, username, 
                userIdUnique, True, sessionName="automatic_cube")
    except Exception as e:
        print("Could not set session for %s" % (username))
        raise e
    xcalarApi.setSession(workbook)
    op = Operators(xcalarApi)
    retina = Retina(xcalarApi)
    xcUdf = XcUdf.Udf(xcalarApi)

    cubeArray = cubesArrays[args.cube]
    importTargetName = args.importTargetName 
    path = args.path 

    params = []
    params.append({
        "paramName": "importTargetName",
        "paramValue": importTargetName
        })
    params.append({
        "paramName": "path",
        "paramValue": os.path.join(path, "datasets")
        })

    availableRetinas = {desc.retinaName for desc in retina.list().retinaDescs}

def uploadDF(dataflowName):
    dataflowStr = None
    udfs = {}
    dataflowPath = os.path.join(path, "dataflows", dataflowName)
    with open(dataflowPath + "/dataflowInfo.json", 'r') as df:
        dataflowStr = df.read()

    if os.path.exists(dataflowPath + "/udfs/"):
        for udf in os.listdir(dataflowPath + "/udfs/"):
            with open(dataflowPath + "/udfs/" + udf, 'r') as udfFile:
                udfs[udf] = udfFile.read()

    retinaBuf = io.BytesIO()
    with tarfile.open(fileobj = retinaBuf, mode = "w:gz") as tar:
        info = TarInfo("dataflowInfo.json")
        info.size = len(dataflowStr)
        tar.addfile(info, io.BytesIO(bytearray(dataflowStr, "utf-8")))

        # # ##udfs directory
        if udfs:
            info = TarInfo("udfs")
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            tar.addfile(info)

            # ##Add udf to the above dir
            for udfName, udfCode in udfs.items():
                info = TarInfo(name = "udfs/" + udfName)
                info.size = len(udfCode)
                info.mode = 0o755
                tar.addfile(info, io.BytesIO(bytearray(udfCode, "utf-8")))

    try:
        retina.delete(dataflowName)
    except:
        print("Dataflow deletion failed!", dataflowName, availableRetinas)

    retina.add(dataflowName, retinaBuf.getvalue())

def runDfAndPublish(dataflowName, publishedTableName):
    start = timeit.default_timer()
    print("Start time: {}".format(datetime.today().strftime("%H:%M:%S")))
    newTableName = dataflowName + "_" + datetime.today().strftime("%Y%m%d%H%M%S")
    print("New Table Name: {}".format(newTableName))
    queryName = "query_" + newTableName
    numRetries = 10

    # First we run the batch dataflow to get the xcalar table
    for i in range(numRetries):
        errorOccurred = False
        try:
            if dataflowName not in availableRetinas:
                uploadDF(dataflowName)
                availableRetinas.add(dataflowName)
            retina.execute(dataflowName, params, newTableName = newTableName, latencyOptimized=False)
            break
        except:
            errorOccurred = True
            sleep(1)
            
    if (errorOccurred):
        print("Failed to execute dataflow {}".format(dataflowName))
        raise
    
    print("Attempting to create/update {}".format(publishedTableName))
    for ii in range(numRetries):
        errorOccurred = False
        try:
            if op.listPublishedTables(publishedTableName).tables:
                op.update(newTableName, publishedTableName)
            else:
                op.publish(newTableName, publishedTableName)
            break
        except:
            errorOccurred = True
            sleep(1)
            
    if errorOccurred:
        print("Failed to publish {}".format(publishedTableName))
        raise

    print("Attempting to coalesce {}".format(publishedTableName))
    for ii in range(numRetries):
        errorOccurred = False
        try:
            op.coalesce(publishedTableName)
            break
        except:
            errorOccurred = True
            sleep(1)
            
    if errorOccurred:
        print("Failed to coalesce {}".format(publishedTableName))
            
    end = timeit.default_timer()
    elapsed = end - start
    print("Update of {} done!".format(publishedTableName))
    print("Run {} done: {:2}s".format(newTableName, str(elapsed)))

def main():
    iterationIdx = 0
    try:
        while True:
            print("====================================")
            print(datetime.now().strftime("%d %b %Y %H:%M:%S"))
            print("====================================")
            
            for cube in cubeArray:
                if cube["enable"]:
                    lastRun = cube.get("lastRun", None)
                    if lastRun is not None:
                        timeNow = datetime.now()
                        timeDiff = timeNow - lastRun

                    if lastRun is None or timeDiff > timedelta(minutes = cube["intervalInMins"]):
                        try:
                            print("Running {}".format(cube["publishedTableName"]))
                            runDfAndPublish(cube["dataflowName"], cube["publishedTableName"])
                            cube["lastRun"] = datetime.now()
                        finally:
                            op.dropTable(cube["dataflowName"] + "_*")
            sleep(10)
    except:
        raise
    finally:
        sessionCleanUp()

def sessionCleanUp():
    session = None
    for sess in workbook.list().sessions:
        if sess.name == workbook.name:
            session = sess
            break
    if not session:
        return
    if session.state == 'Active':
        workbook.inactivate()
    session = None
    for sess in workbook.list().sessions:
        if sess.name == workbook.name:
            session = sess
            break
    if not session:
        return
    if session.state == 'Inactive':
        workbook.delete()
    del workbook

if __name__ == '__main__':
    argParser = argparse.ArgumentParser(description="Generates/Updates dimensions and cubes")
    argParser.add_argument('--xcalar', '-x', help="Ip address/hostname of mgmtd instance", required=True, default="localhost")
    argParser.add_argument('--user', '-u', help="Xcalar User", required=True, default="admin")
    argParser.add_argument('--importTargetName', '-i', help="import target name", required=True, default="Default Shared Root")
    argParser.add_argument('--path', '-p', help="datasets path", required=True, default="xcalar-infra/imdTests/datasets")
    argParser.add_argument('--cube', '-c', help="what cube data to generate", 
                        choices=['ecommTables', 'transacTables'], required=True)
    
    
    args = argParser.parse_args()
    initialise(args)
    
    main()
