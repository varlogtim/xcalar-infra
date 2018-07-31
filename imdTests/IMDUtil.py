import sys
import os
import json
import timeit
import time
import io
import tarfile
from tarfile import TarInfo

### Start Xcalar Code ###
#Xcalar imports. For more information, refer to discourse.xcalar.com
from xcalar.external.LegacyApi.Operators import Operators
from xcalar.external.LegacyApi.Retina import Retina

class IMDOps(object):
    def __init__(self, xcalarApi):
        self.op = Operators(xcalarApi)
        self.retina = Retina(xcalarApi)

    def __createPubTable(self, tableName, info):
        dataflowInfo = {}
        query = []
        synthesizeColumns = []
        parserCols = []
        columnHints = []
        key = ""
        key_type = ""
        opCodeFound = False

        # createRestoreDF(tableName, info)
        if self.op.listPublishedTables(tableName).numTables == 1:
            print("Skiping table ", tableName)
            return

        if len(info["key"]) == 0:
            print("")
            return

        print("Creating IMD table {}".format(tableName))
        start = timeit.default_timer()

        for col in info["columns"]:
            synthCol = {}
            parseCol = {}
            synthCol["sourceColumn"] = tableName + "::" + col["name"]
            parseCol["sourceColumn"] = col["name"]

            if col["name"] == info["opcode"]:
                synthCol["destColumn"] = "XcalarOpCode"
                synthCol["columnType"] = "DfInt64"

                parseCol["destColumn"] = "opcode"
                parseCol["columnType"] = "DfInt64"
                opCodeFound = True
            else:
                synthCol["destColumn"] = col["name"]
                synthCol["columnType"] = col["type"]

                parseCol["destColumn"] = col["name"]
                parseCol["columnType"] = col["type"]

            synthesizeColumns.append(synthCol)
            parserCols.append(parseCol)


        if not opCodeFound:
            synthesizeColumns.append({"sourceColumn": tableName + "::" + info["opcode"],
                                      "columnType": "DfInt64",
                                      "destColumn": "XcalarOpCode"})

        synthesizeColumns.append({"sourceColumn": tableName + "::" + "fn",
                                  "columnType": "DfString",
                                  "destColumn": "fn"})

        synthesizeColumns.append({"sourceColumn": tableName + "::" + "rec",
                                  "columnType": "DfInt64",
                                  "destColumn": "rec"})

        columnHints = [{"columnName": col["sourceColumn"], "type": col["columnType"]} for col in synthesizeColumns]

        prserJsonStr = "{\"recordDelim\":\"\\n\",\"fieldDelim\":\"\\t\",\"isCRLF\":true,\"linesToSkip\":1,\"quoteDelim\":\"\\\"\",\"hasHeader\":true,\"schemaFile\":\"\",\"schemaMode\":\"loadInput\"}"

        parserArgJson = {}
        parserArgJson['recordDelim'] = "\n"
        parserArgJson['fieldDelim'] = "\t"
        parserArgJson['isCRLF'] = True

        load = [
            {
                "operation": "XcalarApiBulkLoad",
                "args": {
                    "dest": ".XcalarDS.{}".format(tableName),
                    "loadArgs": {
                        "parseArgs": {
                            "parserFnName": "default:parseCsv",
                            "parserArgJson": prserJsonStr,
                            "fileNameFieldName": "",
                            "recordNumFieldName": "",
                            "allowFileErrors": False,
                            "allowRecordErrors": False,
                            "schema": parserCols
                        },
                        "sourceArgsList": [
                            {
                                "recursive": True,
                                "path": info["path"],
                                "targetName": info["targetName"],
                                "fileNamePattern": ""
                            }
                        ],
                        "size": 10737418240
                    }
                }
            },
            {
                "operation": "XcalarApiIndex",
                "args": {
                    "source": ".XcalarDS.{}".format(tableName),
                    "dest": "{}-tmp".format(tableName),
                    "prefix": tableName,
                    "key": [
                        {
                            "name": "xcalarRecordNum",
                            "ordering": "Unordered",
                            "keyFieldName": "",
                            "type": "DfInt64"
                        }
                    ],
                },
            },
            {
                "operation": "XcalarApiSynthesize",
                "args": {
                    "sameSession": True,
                    "source": "{}-tmp".format(tableName),
                    "dest": "{}-1".format(tableName),
                    "columns": synthesizeColumns,
                },
            }
        ]
        nxtTab = "{}-1".format(tableName)
        query += load

        if isinstance(info["key"], list):
            setupMap = {
                "operation": "XcalarApiMap",
                "args": {
                    "source": "{}-1".format(tableName),
                    "dest": "{}-map".format(tableName),
                    "eval": []
                }
            }
            # consolidate multiple keys
            evalString = "concat("
            for ii in range(len(info["key"])):
                evalString += "string({})".format(info["key"][ii])

                if ii < len(info["key"]) - 1:
                    evalString += ",\".Xc.\","
                else:
                    evalString += ")"

            setupMap["args"]["eval"].append({"evalString": evalString,
                                             "newField": tableName + "_key"})

            key = tableName + "_key"
            key_type = "DfString"

            keyCreated = True
            query.append(setupMap)
            nxtTab = "{}-map".format(tableName)
        else:
            key = info["key"]
            key_type = info["key_type"]

            keyCreated = False

        rankOver = [
            {
                "operation": "XcalarApiGetRowNum",
                "args": {
                    "source": nxtTab,
                    "dest": "{}-getRowNum".format(tableName),
                    "newField": "XcalarRankOver"
                },
            },
            {
                "operation": "XcalarApiIndex",
                "args": {
                    "source": "{}-getRowNum".format(tableName),
                    "dest": "{}-ranked".format(tableName),
                    "key": [
                        {
                            "name": key,
                            "ordering": "Unordered",
                            "keyFieldName": key,
                            "type": key_type
                        }
                    ],
                },
            }
        ]

        query += rankOver

        tableColumns = []
        for col in info["columns"]:
            if col["name"] == info["opcode"]:
                continue

            tableColumns.append({"columnName": col["name"], "headerAlias": col["name"]})


        if keyCreated:
            tableColumns.append({"columnName": key, "headerAlias": key})

        tableColumns.append({"columnName": "XcalarRankOver", "headerAlias": "XcalarRankOver"})
        tableColumns.append({"columnName": "XcalarOpCode", "headerAlias": "XcalarOpCode"})

        dataflowInfo["tables"] = [
            {
                "name": "{}-ranked".format(tableName),
                "columns": tableColumns
            }
        ]
        dataflowInfo["query"] = query

        dataflowInfo["schema hints"] = columnHints
        
        dataflowStr = json.dumps(dataflowInfo)

        retinaBuf = io.BytesIO()

        with tarfile.open(fileobj = retinaBuf, mode = "w:gz") as tar:
            info = TarInfo("dataflowInfo.json")
            info.size = len(dataflowStr)
            tar.addfile(info, io.BytesIO(bytearray(dataflowStr, "utf-8")))

        try:
            self.retina.delete(tableName)
        except:
            pass

        self.retina.add(tableName, retinaBuf.getvalue())

        try:
            self.retina.execute(tableName, [], tableName)
        except:
            pass

        try:
            self.op.unpublish(tableName)
        except:
            pass

        self.op.publish(tableName, tableName)

        try:
            self.op.dropTable(tableName)
        except:
            pass
        end = timeit.default_timer()
        elapsed = end - start
        print("published table {} in {:.2f}sec!".format(tableName, elapsed))

    def createPubTables(self, tables):
        start = timeit.default_timer()
        for tab in tables:
            self.__createPubTable(tab, tables[tab])
        print("Publishing tables done in {:.2f}sec!".format(timeit.default_timer() - start))
        print("====================================\n")

    def applyUpdates(self, tables):
        print("Updating {} tables: {}".format(len(tables), str(tables.keys())))
        start = timeit.default_timer()
        update_table_names = []
        pub_table_names = []
        for tabName in tables:
            if not self.op.listPublishedTables(tabName).numTables:
                raise ValueError("Xcalar error: published table not found for {}".format(tabName))

            print("Applying update for", tabName)
            retObj = self.retina.getDict(tabName)
            # targetName = retObj["query"][0]["args"]["loadArgs"]["sourceArgsList"][0]["targetName"]
            retObj["query"][0]["args"]["loadArgs"]["sourceArgsList"] = []

            argsDict = {}
            argsDict["recursive"] = False
            argsDict["path"] = tables[tabName]["path"]
            argsDict["targetName"] = tables[tabName]["targetName"]
            argsDict["fileNamePattern"] = ""
            retObj["query"][0]["args"]["loadArgs"]["sourceArgsList"].append(argsDict)
            update_table_name = tabName + '_update'
            try:
                self.op.dropTable(update_table_name)
            except:
                pass
            self.retina.update(tabName, retObj)
            self.retina.execute(tabName, [], update_table_name)
            update_table_names.append(update_table_name)
            pub_table_names.append(tabName)

        numRetries = 10
        for i in range(numRetries):
            errorOccurred = False
            try:
                self.op.update(update_table_names, pub_table_names)
                break
            except:
                errorOccurred = True
                time.sleep(1)

        if (errorOccurred):
            print("Failed to update published tables".format(dataflowName))
            raise

        for tab in update_table_names:
            try:
                self.op.dropTable(tab)
            except:
                pass
        end = timeit.default_timer()
        elapsed = end - start
        print("Updating tables done in {:.2f}sec!".format(elapsed))
        print("====================================\n")
