##
## create a new Data Target in Xcalar.
## pass the path you want to create the target as
## call using xcalar python so it has access to our apis
##
## /opt/xcalar/bin/python3.6 setupTarget.py targetName /someabspath
##

import sys
from xcalar.compute.api.XcalarApi import XcalarApi, XcalarApiStatusException
from xcalar.compute.api.Target2 import Target2
from xcalar.compute.api.Session import Session

targetName = sys.argv[1]
mapPath = sys.argv[2]

xcApi = XcalarApi()
targService = Target2(xcApi)
targService.add('shared', targetName, {'mountpoint':mapPath})
