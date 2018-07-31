import argparse
import json
import hashlib
import time
import timeit
from datetime import datetime

### Start Xcalar Code ###
#Xcalar imports. For more information, refer to discourse.xcalar.com
from xcalar.external.LegacyApi.XcalarApi import XcalarApi
from xcalar.external.LegacyApi.Session import Session
from xcalar.external.LegacyApi.WorkItem import WorkItem
from xcalar.external.LegacyApi.ResultSet import ResultSet
from xcalar.external.LegacyApi.Operators import *
from xcalar.external.LegacyApi.Dataset import *
from xcalar.external.LegacyApi.WorkItem import *
from xcalar.external.LegacyApi.Udf import *
from xcalar.external.LegacyApi.Retina import *
from xcalar.external.LegacyApi.Target import Target
from xcalar.external.LegacyApi.Target2 import Target2
from xcalar.compute.coretypes.DagTypes.ttypes import *

##TODO: Add one more cube which will generate schema
##on fly and generate all the stuff dynamically
class TestEnvironment(object):
    def __init__(self, xcalarApi, exportUrl, env):
        self.xcApi = xcalarApi
        self.username = xcalarApi.session.username
        self.op = Operators(self.xcApi)
        self.udf = Udf(self.xcApi)
        self.retina = Retina(self.xcApi)
        self.exportTarget = Target(self.xcApi)
        self.importTarget = Target2(self.xcApi)
        datasetName = None
        dataset = None

        ##get export and import information from config file
        self.exportUrl = exportUrl
        self.env = env
        
        ##get sessionid, it is not present in session object
        ##need to workaround this way to get it
        self.sessionId = None
        for sess in xcalarApi.session.list().sessions:
            if sess.name == xcalarApi.session.name:
                self.sessionId = sess.sessionId
                break
        self.uploadUdfs()
        self.createTargets()
        
    def uploadUdfs(self):
        udfsFiles = os.listdir("udfs/")
        for pyFile in udfsFiles:
            moduleName=pyFile.split(".")[0].lower()
            print ("Uploading %s" % (moduleName))
            with open("udfs/" + pyFile) as fp:
                self.udf.addOrUpdate(moduleName, fp.read())
        print("All UDFs uplaoded!")

    def createTargets(self):
        #memory and import targets
        targetNames = ["Memory", "s3DatagenImport"]
        types = ["memory", "s3environ"]
        params = {}
        for tName, tType in zip(targetNames, types):
            self.importTarget.add(tType, tName, params)
        self.dataGenTarget = targetNames[0]

        #set export target
        exportTargets = []
        pgExportTarget = {
            'name': 'pgDbDatagenExport',
            'udfModule' : 'pgdb_export_udf',
            'exportUrl' : '/'
        }
        exportTargets.append(pgExportTarget)
        if self.exportUrl:
            exportTarget = {
                'name': 's3DatagenExport',
                'udfModule' : 's3_export_udf',
                'exportUrl' : self.exportUrl
            }
            exportTargets.append(exportTarget)
        for expTarget in exportTargets:
            ##remove if target present
            try:
                self.exportTarget.removeUDF(expTarget['name'])
            except:
                pass
            try:
                udfModule = "/workbook/{}/{}/udf/{}:main".format(self.username, self.sessionId, expTarget['udfModule'])
                self.exportTarget.addUDF(expTarget['name'],
                                    expTarget['exportUrl'],
                                    udfModule)
            except Exception as e:
                print("Warining: Export target creation failed with:", str(e))

        print("Targets created!")


    def loadDataset(self, numRows, importUdf, cubeName):
        timestamp = int(time.time())
        datasetName = "{}.{}.{}".format(self.username,
                    timestamp, cubeName)
        args = {}
        datasetUrl = str(numRows)
        dataset = UdfDataset(self.xcApi, self.dataGenTarget, datasetUrl, 
                datasetName, importUdf, args)
        dataset.load()
        return (dataset, datasetName)

    def getSchema(self, schemaName):
        schema = None
        with open("schemas/" + schemaName) as f:
            return json.load(f)

    def addParamsDF(self, retinaName):
        retObj = self.retina.getDict(retinaName)
        for node in retObj["query"]:
            if node['operation'] == "XcalarApiBulkLoad":
                node['args']['loadArgs']['sourceArgsList'][0]['path'] = "<numRows>"
            elif node['operation'] == "XcalarApiExport":
                node['args']['targetName'] = "<exportTargetName>"
                fileName = node['args']['fileName'].split('-')[1]
                tabName = fileName.split('.')[0]
                fileName = tabName + "/<fileName>" + ".csv"
                node['args']['fileName'] = fileName
                node['args']['createRule'] = 'deleteAndReplace'
                if self.env == "local":
                    node['args']['targetType'] = "file"
                else:
                    node['args']['targetType'] = "udf"
        self.retina.update(retinaName, retObj)

    def doUnion(self, srcTab, destTab, srcCols, prefixName=None):
        ##Doing dedup union to export only unique rows
        evalStr = ""
        cols = []
        unionCols = []
        for col in srcCols[::-1]:
            prefixedCol = "{}".format(col['name'])
            if prefixName:
                prefixedCol = "{}::{}".format(prefixName, prefixedCol)
            if evalStr != "":
                evalStr = "concat(\".Xc.\", {})".format(evalStr)
            colStr = "string({})".format(prefixedCol) if col['type'] != 'DfString' else prefixedCol
            s = "ifStr(exists(" + colStr + "), " + colStr + ", \"XC_FNF\")"
            if evalStr == "":
                evalStr = s
            else:
                evalStr = "concat({}, {})".format(s, evalStr)    
            cols.insert(0, (prefixedCol, col['name']))
        mapTab = "map_{}_{}".format(destTab, int(time.time()))
        self.op.map(srcTab, mapTab, [evalStr], [mapTab])
        indexTab = "index_{}_{}".format(destTab, int(time.time()))
        self.op.indexTable(mapTab, indexTab, mapTab, keyFieldName = mapTab)
        self.op.dropTable(mapTab)
        unionCols.append(XcalarApiColumnT(mapTab, mapTab, 'DfString'))
        unionCols.append(XcalarApiColumnT(prefixName, prefixName, 'DfFatptr'))
        self.op.union([indexTab], destTab, [unionCols], dedup=True)
        self.op.dropTable(indexTab)
        return (destTab, cols)

    def genEcommDFs(self):
        retinaName = "ecommTables"
        dataset, datasetName = self.loadDataset(numRows = 1000,
                                importUdf = "import_udf_ecomm:genData",
                                cubeName = retinaName)
        tabsCreated = ["{}_1".format(retinaName)]
        self.op.indexDataset(dataset.name, tabsCreated[0], 
                "xcalarRecordNum", fatptrPrefixName=datasetName)
        schema = self.getSchema("{}.json".format(retinaName))
        destTables = []
        destColumns = []
        for tab in schema:
            tab, cols = self.doUnion(tabsCreated[0], tab, 
                                schema[tab]['columns'], datasetName)
            destTables.append(tab)
            destColumns.append(cols)
        try:
            self.retina.delete(retinaName)
        except:
            pass
        self.retina.make(retinaName, destTables, destColumns)
        self.addParamsDF(retinaName)
        print("Dataflow {} creation done!".format(retinaName))
        tabsCreated.extend(destTables)
        for tab in tabsCreated:
            self.op.dropTable(tab)
        dataset.delete()

    def genTransacDfs(self):
        retinaName = "transacTables"
        dataset, datasetName = self.loadDataset(numRows = 1000,
                                importUdf = "import_udf_trade:genData",
                                cubeName = retinaName)
        tabsCreated = ["{}_1".format(retinaName)]
        self.op.indexDataset(dataset.name, tabsCreated[0], 
                "xcalarRecordNum", fatptrPrefixName=datasetName)
        schema = self.getSchema("{}.json".format(retinaName))
        destTables = []
        destColumns = []
        for tab in schema:
            tab, cols = self.doUnion(tabsCreated[0], tab, 
                                schema[tab]['columns'], datasetName)
            destTables.append(tab)
            destColumns.append(cols)
        try:
            self.retina.delete(retinaName)
        except:
            pass
        self.retina.make(retinaName, destTables, destColumns)
        self.addParamsDF(retinaName)
        print("Dataflow {} creation done!".format(retinaName))
        tabsCreated.extend(destTables)
        for tab in tabsCreated:
            self.op.dropTable(tab)
        dataset.delete()
        
    def run(self):
        try:
            self.op.dropTable('*')
        except:
            pass

        self.genEcommDFs()
        self.genTransacDfs()
        print("====================================\n")

def parseArgs(args):
    mgmtdUrl="http://%s:9090/thrift/service/XcalarApiService/" % args.xcalar.rstrip()
    xcApi = XcalarApi(mgmtdUrl)
    username = args.user
    userIdUnique = int(hashlib.md5(username.encode("UTF-8")).hexdigest()[:5], 16) + 4000000
    try:
        session = Session(xcApi, username, username, 
                    userIdUnique, True, sessionName=args.session)
    except Exception as e:
        print("Could not set session for %s" % (username))
        raise e
    xcApi.setSession(session)
    return xcApi

if __name__ == '__main__':
    argParser = argparse.ArgumentParser(description="Prime a Xcalar Workbook with the datasets required for the credit score demo")
    argParser.add_argument('--xcalar', '-x', help="Ip address/hostname of mgmtd instance", required=True, default="localhost")
    argParser.add_argument('--user', '-u', help="Xcalar User", required=True, default="admin")
    argParser.add_argument('--session', '-s', help="Name of session", required=True)
    argParser.add_argument('--exportUrl', '-l', help="Where to export the data", required=False, default="/mnt/xcalar/demo")
    args = argParser.parse_args()
    
    xcApi = parseArgs(args)
    prepareEnv = TestEnvironment(xcApi, args.user, exportUrl=args.exportUrl)
    prepareEnv.run()
