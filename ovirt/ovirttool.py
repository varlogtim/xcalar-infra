#!/usr/bin/env python
# -*- coding: utf-8 -*-

"""

Tool to spin up VMs on Ovirt and create Xcalar clusters

Some examples

    ovirttool

        create single VM with all the defaults; no Xcalar installed

    ovirttool --create_xcalar_cluster

        create a single VM with all defaults; installs latest successful build of xcalar as a single-node cluster

    ovirttool --vms=name1,name2,name3 --ram=32 --cores=8 --create_xcalar_cluster=/path/

        create 3 VMs called name1, name2, name3, with 32GB ram and 8 core each,
        and creates a 3 node cluster of those VMs using he custom install dir on netstore at /path/

    ovirttool --ram=32 --cores=8 --create_xcalar_cluster=mycluster --installer=<path>

    ovirttool --ram=16 --cores=4 --create_xcalar_cluster --installer=<path>

    ovirttool --vms=4 --ram=32 --cores=4
"""

import getpass
import socket
import sys
import logging
import requests
import os
import time
import ovirtsdk4 as sdk
import ovirtsdk4.types as types
import shutil
import subprocess
import urllib
import multiprocessing
import random

import paramiko

logging.basicConfig(level=logging.DEBUG, filename='example.log')

MAX_VMS_ALLOWED=6

NETSTORE_IP='10.10.1.107'
XUID = '1001'

RAM_VALID_VALUES = [32,64,128]
CORES_VALID_VALUES = [2,4,8,16]

import argparse
parser = argparse.ArgumentParser()
parser.add_argument("--user", type=str, help="Your SSO username (no '@xcalar.com')")
parser.add_argument("--num_vms", type=int, default=0, help="Number of VMs you'd like to create, or comma sep list of names of VMs you'd like to create")
parser.add_argument('--quick', action='store_true', default=False, help='test')
parser.add_argument('--quickcluster', type=str)
#parser.add_argument("--ram", type=int, choices=RAM_VALID_VALUES, default=32, help="RAM on VM(s) (in GB)")
#parser.add_argument("--cores", type=int, choices=CORES_VALID_VALUES, default=4, help="Number of cores per VM.")
#parser.add_argument("--create_xcalar_cluster", action='store_true', help="Create a cluster of the new VMs.")
#parser.add_argument("--cluster_name", type=str, help="Name you want the cluster to have.  If not supplied will generate random name based on timestamp")
#parser.add_argument("--installer", type=str, default='/last-successful/', help="Path (on NETSTORE) to the Xcalar instance to install on your cluster.  If not supplied, and you've requested a xcalar cluster, will use latest successful build")
#parser.add_argument("--dump", type=str, help="testing")
parser.add_argument("--dont_install_xcalar", action="store_true", default=False, help="testing")
parser.add_argument("--dont_create_cluster", action='store_true', default=False, help="testing")
#parser.add_argument("--create_cluster", action='store_true', help="testing")
parser.add_argument("--homenode", type=str, default='node4-cluster', help="Which node to create the VM(s) on.  Defaults to node4-cluster")
parser.add_argument("--remove_vm", type=str, help="testing purposes")
parser.add_argument("--licfile", type=str, help="Path to XcalarLic.key on your local machine (If not supplied, will look for it in cwd)")
parser.add_argument("--pubsfile", type=str, help="Path to EcdsaPub.key on your local machine (If not supplied, will look for it in cwd)")
#parser.add_argument("--ssh", help="Testing")
args = parser.parse_args()

TMPDIR='/tmp/ovirt_tool/'
CONN=None
PUBSFILENAME='EcdsaPub.key'
LICFILENAME='XcalarLic.key'
LICFILEPATH=None
PUBSFILEPATH=None
REMOTE_TMPDIR=None
#REMOTE_TMPDIR='/tmp/ovirt_tool/' + str(time.time())
ROOT_VM = None
CLUSTER_DIR_REMOTE = None
CLUSTER_DIR_LOCAL = '/mnt/xcalar'
INSTALLER_SH_SCRIPT = 'e2einstaller.sh'
TEMPLATE_HELPER_SH_SCRIPT = 'templatehelper.sh'
ADMIN_HELPER_SH_SCRIPT = 'setupadmin.sh'

'''
See if a vm by given name exist.
If so return the VM obj.
Else return False
'''
def vm_exists(name):

    print("Check if VM by name {} exists...".format(name))

    # Find the virtual imachine:
    vms_service = CONN.system_service().vms_service()
    vmsearch = vms_service.list(search='name=' + name)
    if len(vmsearch):
        print("\tVM by this name exists")
        '''
        print("Found VMs by name... (return first as obj)" + str(vmsearch))
        print("\tVMs by name {} exist... ".format(name))
        print("dictionary : {}".format(str(vmsearch.__dict__)))
        for vm in vmsearch:
            print("VM: {}".format(vm))
        '''
        return vmsearch[0]
    else:
        print ("\tCouldn't find vm {} :(".format(name))
        return False

'''
get vm service for vm of given name
'''
def get_vm_service(name):

    # Find the virtual machine:
    myvm = vm_exists(name)
    if None:
        print("No VM found called {}; can't return VM service!".format(name))
        raise Exception("Can't find service for {} - VM does not exist!".format(name))

    # Locate the service that manages the virtual machine, as that is where
    # the action methods are defined:
    vms_service = CONN.system_service().vms_service()
    return vms_service.vm_service(myvm.id)

'''
    Generate n unique unused names for vms,
    on the cluster.
    Do in convention
    <vm name>, <vm name>-1, so we can put in cluster like thiat
'''
def generate_unique_vm_names(cluster, n):

    print("\nGenerate {} new vm names on cluster {}".format(n, cluster))

    # Get the reference to the "vms" service:
    vms_service = CONN.system_service().vms_service()

    names = []

    # get the first unique vm name
    basevmname = None
    tries = 50
    vmid = random.randint(1,200)
    while True and tries:
        basevmname = "ovirt-tool-auto-vm-" + str(vmid)
        if vm_exists(basevmname):
            tries -= 1
            vmid += 1
        else:
            print("Found base name {}".format(basevmname))
            global ROOT_VM
            ROOT_VM = basevmname
            global REMOTE_TMPDIR
            REMOTE_TMPDIR = '/tmp/ovirt_tool/' + ROOT_VM
            names.append(basevmname)
            break
    if not tries:
        raise Exception("Need to delete some VMs to clear up resources:\n\tpython ovirttool.py --remove_vm=" + myvmname)

    # now base the others off that
    cnt = 0
    for i in range(n-1):
        cnt += 1
        while True:
            vmname = '{}-{}'.format(basevmname, str(cnt))
            if not vm_exists(vmname):
                print("Found new name... {}".format(vmname))
                names.append(vmname)
                break        

    return names

'''
    Create a new vm and wait until you can get ip

    @returns: vm name, ip

    if never find ip throw exception
'''
def create_vm(myvmname, cluster, template):

    #cluster, template = get_template_name(**kwargs)
    print("Create a new VM based on cluster {}, using template {}".format(cluster, template))

    '''
    print("\nget vms service")
    # Get the reference to the "vms" service:
    vms_service = CONN.system_service().vms_service()

    # get a unique vm name
    print("\nFind an unused name on {} for the new vm".format(cluster))
    vmnum = 405
    vmvmname = None
    tries = 50
    while True and tries:
        vmnum+=1
        myvmname = "ovirt-tool-auto-vm-" + str(vmnum)#str(time.time()*1000)
        if vm_exists(myvmname):
            tries -= 1
        else:
            break
    if not tries:
        raise Exception("Need to delete some VMs to clear up resources:\n\tpython ovirttool.py --remove_vm=" + myvmname)
    '''

    # Get the reference to the "vms" service:
    vms_service = CONN.system_service().vms_service()

    # add the vm
    print("No VM by name {} yet; create VM with this name...".format(myvmname))
    vms_service.add(
        types.Vm(
            name=myvmname,
            cluster=types.Cluster(
                name=cluster,
            ),
            template=types.Template(
                name=template,
            ),
        ),
    )
    print("VM added...")

    # get vm service for the new vm (throws exception if can't get)
    print("\nget vm service for {}".format(myvmname))
    vm_service = get_vm_service(myvmname)

    # start vm and bring up
    print("\nBring up {}".format(myvmname))
    bring_up_vm(myvmname)

    # wait for IP to show up
    print("\nGet IP of vm: {}".format(myvmname))
    new_ip = get_vm_ip(myvmname, tries=50)
    # mark if its the root ip
    print("\tIP: {}".format(new_ip))

    print("\nSuccessfully created a new VM!!\n\tVM: {}\n\tIP: {}\n\tCluster: {}\n\tTemplate {}".format(myvmname, new_ip, cluster, template))

    return myvmname, new_ip

def _open_connection():

    print("\nOpen connection to Ovirt engine...")

    # get username if user didn't supply when calling script
    uname = args.user
    if not uname:
        # get user name
        uname = input('Username: ')
    # if they gave the full thing just get the uname part
    if '@' in uname:
        uname = uname.split('@')[0]

    # determine username to send to Ovirt
    # (user accounts are on the profile1 Profile,
    # admin is on the internal Profile)
    if uname == 'admin':
        uname = 'admin@internal'
    else:
        uname = uname + '@xcalar.com@profile1'

    # promopt user for pass
    try:
        p = getpass.getpass()
    except Exception as err:
        print("Error:", err)

    # get the pem certification
    certpath = _get_pem_cert()

    # set up connection
    conn = sdk.Connection(
        url='https://ovirt.int.xcalar.com/ovirt-engine/api',
        #username='admin@internal',
        username=uname,
        password=p,
        debug=True,
        #ca_file='/home/jolsen/xcalar-infra/ovirt/toyproblems/ca.pem',
        ca_file=certpath,
        log=logging.getLogger(),
    )

    return conn

'''
    returns path to a cert to use
'''
def _get_pem_cert():

    print("get perm cert")
    # get the pem cert from netstore
    response = requests.get('http://netstore/infra/ovirt/ovirt.int.xcalar.com.pem')
    #print(response.text)
    # save in a tmp file and return that
    tmpfilename = 'ctmp.pem'
    if not os.path.isdir(TMPDIR):
        os.makedirs(TMPDIR)
    tmpfilepath = TMPDIR + tmpfilename
    pemfile = open(tmpfilepath, 'w')
    pemfile.write(response.text)
    pemfile.close()
    return tmpfilepath

def _close_connection(conn):

    print("close connection to ovirt engine...")

    if conn:
        print("Active connection; close it")
        conn.close()
    else:
        print("Connection pass is null")

'''
    Copy necessary license files on to a remote node
    @node: IP of node to copy files on to
'''
def copy_lic_files(node, dest='/etc/xcalar'):

    print("\nCopy licences files in to {} via scp".format(node))

    '''
         scp in the license files in to the VM
    '''
    files = [LICFILEPATH, PUBSFILEPATH]
    for licfile in files:
        print("dest: " + dest)
        print("node: " + node)
        print("lic file: " + licfile)
        scp_file(node, licfile, dest)

'''
    scp a file from the local machine to a remove machine
    @node ip of remote machine to copy file on to
    @localfilepath filepath of the file on the local machine
    @remotefilepath filepath where to put the file on the remote machine
'''
def scp_file(node, localfilepath, remotefilepath):

    print("\nSCP: Copy file {} from host, to {}:{}".format(localfilepath, node, remotefilepath))

    cmd = 'scp -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no ' + localfilepath + ' root@' + node + ':' + remotefilepath
    print("\n\t~ {}\n".format(cmd))
    os.system(cmd)
    #bring_up_xcalar(node)

def run_ssh_cmds(host, cmds):

    print("\nTry ssh root@{} ...\n\n".format(host))

    # run the cmds one by one.  it will create a new session each time
    errorFound = False
    for cmd in cmds:
        time.sleep(5)
        status = None
        extraops = {}
        if len(cmd) > 1:
            extraops['timeout'] = cmd[1]
        status = run_ssh_cmd(host, cmd[0], **extraops)
        if status:
            errorFound = True

    if errorFound:
        raise Exception("Found error while executing one of the commands!!!")

def run_ssh_cmd(host, command, port=22, user='root', bufsize=-1, key_filename='', timeout=120, pkey=None):
    print("[" + user + "@" + host +  "] " + command)
    print("\n~ Will try to 'ssh {}@{}' .. ".format(user, host))
    client = paramiko.SSHClient()
    print("\tD: Made Client obj...")
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print("\tD: try to connect on port {}".format(port))
    client.connect(hostname=host, port=port, username=user)#, key_filename=key_filename, banner_timeout=10)
    print("\tconnected to : {}".format(host))
    chan = client.get_transport().open_session()
    print("\tOpened session...")
    chan.settimeout(timeout)
    print("\tD: set timeout to {}".format(timeout))
    chan.set_combine_stderr(True)
    print("\tD: chan3")
    chan.get_pty()
    print("\t\t~~ SEND CMD: {}".format(command))
    print("[" + user + "@" + host +  "] " + command, end='')
    chan.exec_command(command)
    print("\t\t\tD: success")
    stdout = chan.makefile('r', bufsize)
    print("\tReading stdout ...")
    print("\t\t\tD: made a file")
    stdout_text = stdout.read()
    print("\t\t\tstdout: {}".format(stdout_text))
    status = int(chan.recv_exit_status())
    print("\t\t\tstatus: {}".format(status))
    if status:
        print("\tGot non-0 status!!  stdout text:\n{}".format(stdout_text))

    client.close()
    print("\tclosed client connection")
    return status




'''
    provisions n vms in parallel.
    waits for all vms to come up with ips displaying
    Return a list of names of vms created in Ovirt
'''
def provision_vms(n):

    print("\nProvision {} vms".format(n))

    # create num vms with these attributes
    cluster, template = get_template_name()
    vm_names = generate_unique_vm_names(cluster, n)
    print("Got names: {}".format(vm_names))
    procs = []
    for newvm in vm_names:

        print("\nFork new process to create a new VM by name {}".format(newvm))
        proc = multiprocessing.Process(target=create_vm, args=(newvm, cluster, template))
        proc.start()
        # sleep
        time.sleep(20)
        print("Complete sleep... start new...")
        procs.append(proc)

    # wait for the processes
    process_wait(procs)

    return vm_names

'''
    Install xcalar on node with given ip
    Copy in helper shell scripts used for instlalation
    and cluster creation
    start service if requested
'''
def setup_xcalar(nodename, ip, start=False):

    print("\nCopy in license files and installer script on {} (IP: {})".format(nodename, ip))

    # create tmp dir to hold the files
    run_ssh_cmd(ip, 'mkdir -p {}'.format(REMOTE_TMPDIR))

    # copy all these files in to that dir (each el is [local filepath, destination filepath]
    fileslist = [[PUBSFILEPATH, REMOTE_TMPDIR + '/' + PUBSFILENAME], # i want to rename to the std name in case they supplied a file with a diff name, because e2e script will call by st name
        [LICFILEPATH, REMOTE_TMPDIR + '/' + LICFILENAME],
        [TEMPLATE_HELPER_SH_SCRIPT, REMOTE_TMPDIR],
        [ADMIN_HELPER_SH_SCRIPT, REMOTE_TMPDIR],
        [INSTALLER_SH_SCRIPT, REMOTE_TMPDIR]]
    for filedata in fileslist:
        scp_file(ip, filedata[0], filedata[1])

    # run the shell script over ssh and return the status
    #cmd = 'ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no root@{} {} {} {}'.format(nodeip, installerScriptRemotePath, nodename, start)
    remotefilepath = REMOTE_TMPDIR + '/' + INSTALLER_SH_SCRIPT
    installScript = get_latest_RC_prod() # for now just get latest RC on netstore.  this path should be rel netstore root
    cmds = [['chmod u+x ' + remotefilepath],
             ['/bin/bash ' + remotefilepath + ' ' + installScript + ' ' + nodename + ' ' + ip + ' | tee installlog.log', 600]]
    run_ssh_cmds(ip, cmds)

def process_wait(procs):

    # wait for all the processes to complete
    while procs:
        print("\t:: Check processes... ({} remain)".format(len(procs)))
        for i, proc in enumerate(procs):
            if proc.is_alive():
                time.sleep(10)
                print("process still alive...")
            else:
                exitcode = proc.exitcode
                print("process completed with exit code: {}".format(exitcode))
                if exitcode:
                    raise Exception("Non-0 exit code ")
                del procs[i]
                break

    print("All processes completed with 0 exit code")

'''
    List of VM names as they appear in Ovirt
    For each VM, fork process to install and setup xcalar.
    Once xcalar installation completes on all of them,
    form in to a cluster unless specified otherwise
'''

def initialize_xcalar(nodes, nocluster=False):

    print("\nSetup xcalar on node set")

    procs = []
    ips = []
    for node in nodes:
        # get ip
        ip = get_vm_ip(node) 
        ips.append(ip)
        print("\nStart new process to setup xcalar on {}, {}".format(node, ip))
        proc = multiprocessing.Process(target=setup_xcalar, args=(node, ip))
        procs.append(proc)
        proc.start()

    # wait
    process_wait(procs)
    
    # form the nodes in to a cluster if requested
    if not nocluster and len(ips) > 1:
        create_cluster(ips)

'''
    Configure a node to be part of a cluster
    by generating its default.cfg with a nodelist,
    and bringing up the node
    @node: ip of node
    @nodeliststr: string of ips in the cluster ws sep i.e., '10.10.2.30 10.10.2.31'
'''
def configure_cluster_node(node, nodeliststr, start=True):

    print("\nConfigure cluster node of {}, nodelist: {}".format(node, nodeliststr))

    # generate config file with the nodelist and start xcalar service
    # mount the central cluster dir on netstore
    remotefilepath = REMOTE_TMPDIR + '/' + TEMPLATE_HELPER_SH_SCRIPT
    print("cluster dir: {} {}".format(CLUSTER_DIR_LOCAL, CLUSTER_DIR_REMOTE))

    print("remote filepath: {}".format(remotefilepath))
    #freenas2.int.xcalar.com:/mnt/public/netstore/ /mnt/xcalar
    cmds = [['mkdir -p ' + CLUSTER_DIR_LOCAL + '; mount -t nfs  ' + NETSTORE_IP + ':/mnt/public/netstore/' + CLUSTER_DIR_REMOTE + ' ' + CLUSTER_DIR_LOCAL + '; chown ' + XUID + ':' + XUID + ' ' + CLUSTER_DIR_LOCAL, 60],
            ['chmod u+x ' + remotefilepath],
            ['/bin/bash ' + remotefilepath + ' ' + CLUSTER_DIR_LOCAL + ' ' + nodeliststr]]
    if start:
        print("Will also start xcalar service....")
        cmds.append(['service xcalar start', 120])
        cmds.append(['chmod u+x ' + REMOTE_TMPDIR + '/' + ADMIN_HELPER_SH_SCRIPT])
        cmds.append(['/bin/bash ' + REMOTE_TMPDIR + '/' + ADMIN_HELPER_SH_SCRIPT])
    run_ssh_cmds(node, cmds)

'''
    Create a dir on netstore by the cluster name
    (so cluster nodes can mount as shared storage)
'''
def create_cluster_dir():

    # create a dir on netstore, name after root node
    global CLUSTER_DIR_REMOTE
    CLUSTER_DIR_REMOTE = 'ovirtgen/' + ROOT_VM

    # do it on netstore
    cmd = 'sudo mkdir -p /netstore/{}/config'.format(CLUSTER_DIR_REMOTE)
    print("rn cmd: {}".format(cmd))
    os.system(cmd)
    cmd = 'sudo chown ' + XUID + ':' + XUID  + ' /netstore/' + CLUSTER_DIR_REMOTE
    cmd2 = 'sudo chown ' + XUID + ':' + XUID  + ' /netstore/' + CLUSTER_DIR_REMOTE + '/config'
    print("rn cmd: {}".format(cmd))
    print("rn cmd: {}".format(cmd2))
    os.system(cmd)
    os.system(cmd2)

'''
    List of IPs of nodes with xcalar installed.
    For each node, fork process to configure the node
    as part of a cluster and bring up xcalar
'''
def create_cluster(nodeips, start=True):
    print("root vm: {}".format(ROOT_VM))
    # create dir for cluster on netstore
    create_cluster_dir()
    
    # for each node, generate config file with the nodelist
    # and then bring up the xcalar service
    nodelist = ' '.join(nodeips)
    print("\nCreate cluster of nodes : {}".format(nodelist))
    procs = []
    for ip in nodeips:
        print("\n\tFork cluster config for {} [node list: {}]\n".format(ip, nodelist))
        proc = multiprocessing.Process(target=configure_cluster_node, args=(ip, nodelist))
        procs.append(proc)
        proc.start()
        time.sleep(10)

    # wait for all the proceses to complte
    process_wait(procs)

    # display to them
    print("\n\n~~~~~~~~~~ A NEW CLUSTER EXISTS ~~~~~~~~~~")
    print("\n\thttps://{}:8443".format(nodeips[0]))
    print("\n\t\tusername: xdpadmin")
    print("\t\tpassword: Welcome1")
    print("\nRoot VM: {}".format(ROOT_VM))
    print("\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")

def get_latest_RC_prod():

    return 'builds/Release/xcalar-latest-installer-prod'

def get_vm_ip(name, tries=10):

    print("Try to get IP of VM {} (try {} times)".format(name, tries))

    print("get the vm service")
    vm_service = get_vm_service(name)

    print("Try {} times to get devices".format(tries))
    while True and tries:

        print("Get deivce list...")
        devices = vm_service.reported_devices_service().list()

        for device in devices:
            print("\tFound device: {}".format(device.name))
            if device.name == 'eth0':
                print("\tits the IP of the eth0 i want... get ip")
                ips = device.ips
                for ip in ips:
                    print("\t\tip: {}".format(ip.address))
                    # it will return mac address and ip address dont return mac address
                    try:
                        socket.inet_aton(ip.address)
                        #print("this is the ip you want: {}".format(ip.address))
                        return ip.address
                    except Exception as e:
                        print("\t\t(this is probably a mac address; dont return it)")

        # if here didn't find try again if possible
        print("Tries left: {}".format(tries))
        time.sleep(5)
        tries-=1

    # never found!
    raise Exception("Never found IP for vm: {}".format(name))

def bring_up_vm(name):

    vm_service = get_vm_service(name)

    print("\nStart service on {}".format(name))
    timeout=60
    while True and timeout:
        try:
            # start the vm
            vm_service.start()
            print("started service!")
            break
        except Exception as e:
            if 'VM is locked' in str(e):
                time.sleep(5)
                timeout-=1
                print("vm is locked... try again...")
            else:
                raise SystemExit("Got another error I don't know about: {}".format(str(e)))

    # Wait till the virtual machine is up:
    print("\nWait for {} to come up".format(name))
    timeout=120
    while True:
        vm = vm_service.get()
        if vm.status == types.VmStatus.UP:
            print("vm is up!")
            return True
        else:
            print("VM not up yet....")
            time.sleep(5)
            timeout-=1

    # if here never got it up
    raise Exception("Could not bring up VM {}".format(name))

'''
    Return name of template and cluster template is on,
    depending on what args requestesd (RAM, num cores, etc.)
'''
def get_template_name(**kwargs):

    '''
    @TODO:
        Select the template based on their preferences
        of RAM, etc.
        For now, just base on the node specified,
        or if no node use node4
    '''

    # make so the value is a hash with keys for RAM, cores, etc.
    #and appropriate template for now just one std template each
    node_templates = {
        #'node1-cluster': {'Blank'},
        'node2-cluster': 'ovirtCLI_test_template',
        #'node3-cluster': {},
        'node4-cluster': 'ovirt_cli_tool_template_node4',
    }

    # check that the node arg a valid option
    if args.homenode in node_templates.keys():
        ## todo - there should be templates for all the possible ram/cores/etc configs
        return args.homenode, node_templates[args.homenode]
    else:
        raise Exception("No template found to use.\nValid nodes: {}".format(",".join(node_templates.keys())))

'''
    Pretty print the names of available vms
'''
def list_vms():

    vms_service = CONN.system_service().vms_service()
    vms = vms_service.list()
    print("\n~ Available VMS:: ~\n")
    for vm in vms:
        print("\t%s: %s" % (vm.name, vm.id))
    print("\n ~~")

'''
    Remove a vm of a given name.
    Return True on successfull removal
    If VM does not exist returns None
'''
def remove_vm(name):

    print("\nRemove VM {} from Ovirt".format(name))

    # check if vm exists
    if not vm_exists(name):
        print("No VM by name : {}".format(name))
        list_vms()
        return None

    # get the ip
    vm_ip = get_vm_ip(name)
    # release the ip
    cmds = [['dhclient -v -r']]
    run_ssh_cmds(vm_ip, cmds)    

    print("Get VM service...")
    vm_service = get_vm_service(name)

    print("\nStop VM")
    timeout=60
    while True and timeout:
        try:
            vm_service.stop()
            break
        except Exception as e:
            timeout-=1
            time.sleep(5)
            print("still getting an exception...." + str(e))

    timeout=60
    print("\nWait for service to come down")
    while True and timeout:
        vm = vm_service.get()
        if vm.status == types.VmStatus.DOWN:
            print("vm status: down!")
            break
        else:
            timeout -= 1
            time.sleep(5)

    print("\nRemove VM")
    timeout = 5
    while True and timeout:
        try:
            vm_service.remove()
            break
        except Exception as e:
            time.sleep(5)
            if 'is running' in str(e):
                print("vm still running... try again...")
            else:
                raise SystemExit("unexepcted error when trying to remve vm, {}".format(str(e)))

    print("\nWait for VM to be gone from vms service...")
    timeout = 20
    while True and timeout:
        if vm_exists(name):
            print("Vm still exist...")
            time.sleep(5)
            timeout -= 1
        else:
            print("VM {} no longer exists to vms".format(name))
            break

    print("\n\nSuccessfully removed VM: {}".format(name))
    return True

''' test method '''
def dump_vm_data(name):

    print("get vms service")
    # Get the reference to the "vms" service:
    vms_service = CONN.system_service().vms_service()

    # Find the virtual machine:
    vmsearch = vms_service.list(search='name=' + name)
    if len(vmsearch):
        print("got all these: " + str(vmsearch))
        newvm = vmsearch[0]
        print("got the new vm")
        print("DATA:\n" + str(newvm.__dict__))
    else:
        raise SystemExit("Couldn't find vm {} :(".format(name))

def init():

    # only need to do this if they're making vms to install xcalar on
    if args.num_vms or args.quick:
        # if they didn't supply lic or pub file,
        # make sure ther eis one in their cwd
        print("\nMake sure license keys are present....")
        cwd = os.getcwd()

        global LICFILEPATH
        LICFILEPATH = args.licfile
        if not LICFILEPATH:
            LICFILEPATH = LICFILENAME
            print("\tYou did not supply --licfile option... will look in cwd for {}...".format(LICFILEPATH))
        # normalize
        LICFILEPATH = os.path.abspath(LICFILEPATH)
        if not os.path.exists(LICFILEPATH):
            raise Exception("\nError: File {} does not exist!  (Re-run with --licfile=<path to your licence file>, or, copy the file in to the directory you are running this script from".format(LICFILEPATH))
        print("\tfound {}".format(LICFILEPATH))

        global PUBSFILEPATH
        PUBSFILEPATH = args.pubsfile
        if not PUBSFILEPATH:
            PUBSFILEPATH = PUBSFILENAME
            print("\tYou did not supply --pubsfile option... will look in cwd for {}...".format(PUBSFILEPATH))
        PUBSFILEPATH = os.path.abspath(PUBSFILEPATH)
        if not os.path.exists(PUBSFILEPATH):
            raise Exception("\nFile {} does not exist!  (Re-run with --pubsfile=<path to your licence file>, or, copy the file in to the directory you are running this script from".format(PUBSFILEPATH))
        print("\tfound {}".format(PUBSFILEPATH))

def summary(vmdata):

    print("\n\n--------FULL VM SUMMARY-----------")
    print("")
    for i, data in enumerate(vmdata):
        vmname = data[0]
        ip = data[1]
        url = 'https://{}:8443'.format(ip)
        print("\nVM REQUEST #{}".format(i))
        print("\n\tname: {}\n\tIP: {}".format(vmname,ip))
    print("\n---------------------------")

if __name__ == "__main__":

    '''
        init
    '''
    init()

    #open connection
    CONN = _open_connection()

    if args.remove_vm:
        # in case they gave , sep l ist remove all those
        vms_to_remove = args.remove_vm.split(',')
        for vm in vms_to_remove:
            remove_vm(vm)
        sys.exit(0)

    ''' validation '''
    vms = []
    if not args.num_vms:
        print("Please re-run this script with arg --num_vms=<number of vms you want>")
        sys.exit(0)
    elif args.num_vms > MAX_VMS_ALLOWED:
        print("Pleasae re-run this script with a value < {} for --num_vms ".format(MAX_VMS_ALLOWED))
        sys.exit(0)

    ''''
        main driver
    '''

    # returns list names of vms created
    vms = provision_vms(args.num_vms)
    if not args.dont_install_xcalar:
        # installs xcalar on all the vms in parallel, then forms in to a cluster unless specified not to
        initialize_xcalar(vms, nocluster=args.dont_create_cluster)

    #summary()

    # close connection
    _close_connection(CONN)

