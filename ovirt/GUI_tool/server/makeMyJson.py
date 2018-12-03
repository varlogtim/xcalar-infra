'''
This will spit out a json of RC builds.  For consumption by Ovirt GUIs Flask server

useage:
  python makemyjson.py MYJSONFILE.json

It'll make the file called MYJSONFILE.json
'''

import os
import re
import json
import sys

def getDirList(baseDir="/netstore/builds/ReleaseCandidates/", regex=None):
    baseDir = "/netstore/builds/ReleaseCandidates/"
    # get all the directory names in this baseDir.
    # this are not the installers themselves and will still need
    # to traverse in them as the dir structure is differently named
    # in each
    if not os.path.isdir(baseDir):
        raise Exception("{} is not a valid directory, or not accessible by this machine".format(baseDir))
    pattern = None
    if regex:
        pattern = re.compile(regex)
    subDirs = {}
    for dI in os.listdir(baseDir):
        if os.path.isdir(os.path.join(baseDir, dI)):
            # if pattern supplied match it
            if (not pattern or (pattern and pattern.match(dI))):
                dirRoot = os.path.join(baseDir, dI)
                buildRoot = getBuildFlavorRoot(dirRoot)
                if not buildRoot:
                    next
                else:
                    rpmInstallers = getRpmInstallers(buildRoot)
                    if rpmInstallers:
                        #subDirs[dirRoot] = rpmInstallers
                        subDirs[dI] = rpmInstallers
    return subDirs

def getBuildFlavorRoot(buildDirRoot):
    # see how far to go for 'prod' and/or 'debug' dirs
    dirStop = None
    for root, dirs, files in os.walk(buildDirRoot, topdown=False):
        dirStop = getReleaseTopLevel(root, dirs)
        print("dir stop")
        print(dirStop)
        if dirStop:
            break
    if not dirStop: # did not find any
        print("didn't find any releases")
        return []
    print("Releases will be rooted here: " + dirStop)
    return dirStop

def getRpmInstallers(buildDirRoot):
    # this should be the root of a release. (where 'prod', 'debug', etc. live)
    # get the rpm installers within those
    rpmInstallers = {}
    for dI in os.listdir(buildDirRoot):
        baseDir = os.path.join(buildDirRoot, dI)
        if os.path.isdir(baseDir):
            # probably a release dir, let's check!
            rpmInstaller = getRpmInstallerFromBase(baseDir)
            if rpmInstaller:
                rpmInstallers[dI] = rpmInstaller
    return rpmInstallers

def getRpmInstallerFromBase(root):
    # check for filenames with '-installer' in it
    validPatterns = [re.compile(".*-installer$"), re.compile(".*-installer-OS.*")]
    foundRpm = []
    for dI in os.listdir(root):
        joinedName = os.path.join(root, dI)
        if os.path.isfile(joinedName):
            # make sure it's not one of the shell scripts
            #fileparts = os.path.splitext(joinedName)
            #if fileparts[len(fileparts)-1] == '.sh':
            #    print("it's a shell script")
            for pattern in validPatterns:
                if pattern.match(joinedName):
                    foundRpm.append(joinedName)
                    break

    if len(foundRpm) == 1:
        return foundRpm[0]
    elif len(foundRpm) > 1:
        # sometimes you're having more than one.
        # there's a bug where multiple builds are congregating.
        # sort and take the latest
        foundRpm.sort()
        print("HIT BUG:: Found more than one rpm installer in {}: {}".format(root, foundRpm))
    return None # didn't find any

def getReleaseTopLevel(root, dirList):
    print(dirList)
    print(root)
    commonFlavors = ["prod", "debug"]
    for name in dirList:
        #print(os.path.join(root, name))
        if name in commonFlavors:
            # get dirs from this level
            releaseBasePathDirname = os.path.dirname(name)
            releaseBasePath = os.path.join(root, releaseBasePathDirname)
            print("at this level: " + releaseBasePath)
            return releaseBasePath
 
if len(sys.argv) < 2:
    raise Exception("Please supply a filename")
OUTFILE = sys.argv[1] # 0 is name of python script!
if os.path.isfile(OUTFILE):
    raise Exception("{} already exists!".format(OUTFILE))
else:
    myDirs = getDirList(regex=".*1\.4.*")
    print(myDirs)
    myJson = json.dumps(myDirs)
    print(myJson)

    with open(OUTFILE, 'w') as outfile:  
        json.dump(myDirs, outfile, indent=4, sort_keys=True)
