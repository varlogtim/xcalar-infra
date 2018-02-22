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
import paramiko

logging.basicConfig(level=logging.DEBUG, filename='example.log')

RAM_VALID_VALUES = [32,64,128]
CORES_VALID_VALUES = [2,4,8,16]

import argparse
parser = argparse.ArgumentParser()
parser.add_argument("--user", type=str, help="Your SSO username (no '@xcalar.com')")
#parser.add_argument("--vms", type=int, default=1, help="Number of VMs you'd like to create, or comma sep list of names of VMs you'd like to create")
#parser.add_argument("--ram", type=int, choices=RAM_VALID_VALUES, default=32, help="RAM on VM(s) (in GB)")
#parser.add_argument("--cores", type=int, choices=CORES_VALID_VALUES, default=4, help="Number of cores per VM.")
#parser.add_argument("--create_xcalar_cluster", action='store_true', help="Create a cluster of the new VMs.")
#parser.add_argument("--cluster_name", type=str, help="Name you want the cluster to have.  If not supplied will generate random name based on timestamp")
#parser.add_argument("--installer", type=str, default='/last-successful/', help="Path (on NETSTORE) to the Xcalar instance to install on your cluster.  If not supplied, and you've requested a xcalar cluster, will use latest successful build")
#parser.add_argument("--dump", type=str, help="testing")
parser.add_argument("--create_one_node_cluster", action='store_true', help="testing")
parser.add_argument("--homenode", type=str, default='node4-cluster', help="Which node to create the VM(s) on.  Defaults to node4-cluster")
parser.add_argument("--remove_vm", type=str, help="testing purposes")
parser.add_argument("--licfile", type=str, help="Path to XcalarLic.key on your local machine (If not supplied, will look for it in cwd)")
parser.add_argument("--pubsfile", type=str, help="Path to EcdsaPub.key on your local machine (If not supplied, will look for it in cwd)")
#parser.add_argument("--ssh", help="Testing")
args = parser.parse_args()

TMP_DIR='/tmp/ovirt_tool/'
CONN=None
LICFILEPATH=None
PUBSFILEPATH=None

def create_one_node_cluster(**kwargs):
    print("\nCreate a new VM")
    vmname, ip = create_vm(**kwargs)
    #print("\tCreated VM: {} with IP : {}".format(vmname, ip))

    #create_xcalar_cluster([new_ip])
    print("\nMake VM {} @ ip {} in to a single node xcalar cluster.".format(vmname, ip))
    make_vm_into_single_node_cluster(ip)
    print("Success! VM {} brought up as single node cluster!!\n".format(vmname))

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
    if myvm is None:
        print("No VM found called {}; can't return VM service!".format(name))
        raise Exception("Can't find service for {} - VM does not exist!".format(name))

    # Locate the service that manages the virtual machine, as that is where
    # the action methods are defined:
    vms_service = CONN.system_service().vms_service()
    return vms_service.vm_service(myvm.id)

'''
    Create a new vm and wait until you can get ip

    @returns: vm name, ip

    if never find ip throw exception
'''
def create_vm(**kwargs):

    cluster, template = get_template_name(**kwargs)
    print("Create a new VM based on cluster {}, using template {}".format(cluster, template))

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
    if not os.path.isdir(TMP_DIR):
        os.makedirs(TMP_DIR)
    tmpfilepath = TMP_DIR + tmpfilename
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

def create_cluster(**kwargs):

    get_installer_from_netstore()

    '''
    # custom install dir on netstore
    installdir = 'latest-successful'
    if 'installdir' in kwargs:
        installdir = kwargs['insatlldir']
    # get the installer
    accessiblefilepath = get_installer_from_netstore(installdir)

    # get one of the vms...
    node
    if 'nodes' in kwargs:
        node = kwargs['nodes'][0]
    '''

def get_installer_from_netstore(installpath=0):

    if not installpath:
        installpath = 'builds/Release/xcalar-latest/prod/xcalar-1.3.0-1548-installer'
    url = 'http://netstore/' + installpath
    print("call at url " + url)
    response = requests.get(url, stream=True)
    print("got response...")
    with open('afile', 'wb') as out_file:
        shutil.copyfileobj(response.raw, out_file)
    del response

def create_xcalar_cluster(hosts):

    print("Install xcalar on all hosts: {}, then join as cluster".format(hosts))

    for host in hosts:
        install_xcalar(host)
    # join as cluster

    # bring up all nodes
    for host in hosts:
        bring_up_xcalar(host)

'''
    Copy filepaths on local machine, to remote host at a path on that host
    @host: remote host to copy files on to
    @files: list of filespaths of files on local machine to copy
    @loc: path to copy the files in to on host
'''
def copy_lic_files(host, files, loc):

    print("\nCopy licences files in to {} via scp".format(host))

    '''
         scp in the license files in to the VM
    '''
    for myfile in files:
        cmd = 'scp -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no ' + myfile + ' root@' + host + ':' + loc
        print("\n\t~ {}\n".format(cmd))
        os.system(cmd)

'''
    Given the IP of a VM, install xcalar on it
    and bring up
'''
def make_vm_into_single_node_cluster(host):

    '''
        Copy in latest RC installer and install Xcalar on host
    '''
    print("\nInstall Xcalar on {}".format(host))
    cmds = [['echo "hellow"'],
            ['curl http://netstore/' + get_latest_RC_prod() + ' -o installer.sh', 300],
            ['bash installer.sh --nostart --caddy --startonboot | tee /tmp/installer' + str(time.time()) + '.log',1000]]
    run_cmds(host, cmds)

    '''
        copy the lic files
    '''
    copy_lic_files(host, [LICFILEPATH, PUBSFILEPATH], '/etc/xcalar')

    '''
        post installation
    '''
    print("\nSetup admin acct; perform post-installation tasks")
    cmds = [# this will set up an admin account
            ['mkdir -p /var/opt/xcalar/config'],
            ["echo '{" + '"username":"admin","password":"6d51d4b15ded3bc357f6f1547de49cc81579e6a3b1ec85bbf50dcca20618d1c4","email":"support@xcalar.com","defaultAdminEnabled":"true"' + "}' " + '> /var/opt/xcalar/config/defaultAdmin.json'],
            ['chmod 0600 /var/opt/xcalar/config/defaultAdmin.json'],
            # ted had to do this, too
            ['chown -R xcalar:xcalar /var/opt/xcalar/config'],
            # this will change the hostname to localhost (was having issue with service starting before this)
            ['/opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - localhost > /etc/xcalar/default.cfg'],
            # for now set this permission because my old VM im using as the template has some permissions messing this up
            #['sudo chown -R xcalar:xcalar /tmp/xcalar_sock'],
            # restart XCE, intermittent problem with service coming back up
            ['service xcalar stop-supervisor'],
            ['service xcalar start | tee /tmp/servicestart' + str(time.time()), 200]]
    run_cmds(host,cmds)

    print("\n\n\n\n\tTry: https://" + host + ":8443\n\n\t\tusername: admin\n\n")

def run_cmds(host, cmds):

    print("\nTry ssh root@{} ...\n\n".format(host))

    # run the cmds one by one.  it will create a new session each time
    errorFound = False
    for cmd in cmds:
        time.sleep(5)
        status = None
        extraops = {}
        if len(cmd) > 1:
            extraops['timeout'] = cmd[1]
        status = send_cmd(host, cmd[0], **extraops)
        if status:
            errorFound = True

    if errorFound:
        raise Exception("Found error while executing one of the commands!!!")

def send_cmd(host, command, port=22, user='root', bufsize=-1, key_filename='', timeout=10, pkey=None):
    print("[" + user + "@" + host +  "] " + command)
    #print("\n~ Will try to 'ssh {}@{}' .. ".format(user, host))
    client = paramiko.SSHClient()
    #print("\tD: Made Client obj...")
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    #print("\tD: set missing host key")
    client.connect(hostname=host, port=port, username=user)#, key_filename=key_filename, banner_timeout=10)
    #print("\tconnected to : {}".format(host))
    chan = client.get_transport().open_session()
    #print("\tOpened session...")
    chan.settimeout(timeout)
    #print("\tD: set timeout to {}".format(timeout))
    chan.set_combine_stderr(True)
    #print("\tD: chan3")
    chan.get_pty()
    #print("\t\t~~ SEND CMD: {}".format(command))
    #print("[" + user + "@" + host +  "] " + command, end='')
    chan.exec_command(command)
    #print("\t\t\tD: success")
    stdout = chan.makefile('r', bufsize)
    #print("\tReading stdout ...")
    #print("\t\t\tD: made a file")
    stdout_text = stdout.read()
    #print("\t\t\tstdout: {}".format(stdout_text))
    status = int(chan.recv_exit_status())
    #print("\t\t\tstatus: {}".format(status))
    if status:
        print("\tGot non-0 status!!  stdout text:\n{}".format(stdout_text))

    client.close()
    #print("\tclosed client connection")
    return status

def get_latest_RC_prod():

    return 'builds/Release/xcalar-latest/prod/xcalar-1.3.0-1548-installer'

def get_vm_ip(name, tries=1):

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

    # only need to do this if they're making cluster
    if args.create_one_node_cluster:
        # if they didn't supply lic or pub file,
        # make sure ther eis one in their cwd
        print("\nMake sure license keys are present....")
        cwd = os.getcwd()

        global LICFILEPATH
        LICFILEPATH = args.licfile
        licfilename = 'XcalarLic.key'
        print("{}...".format(licfilename))
        if not LICFILEPATH:
            print("\tYou did not supply --licfile option... will look in cwd for file {}...".format(licfilename))
            LICFILEPATH = cwd + '/' + licfilename
        # normalize
        LICFILEPATH = os.path.abspath(LICFILEPATH)
        if not os.path.exists(LICFILEPATH):
            raise Exception("\nError: File {} does not exist!  (Re-run with --licfile=<path to your licence file>, or, copy the file in to the directory you are running this script from".format(LICFILEPATH))
        print("\tfound {}".format(LICFILEPATH))

        global PUBSFILEPATH
        PUBSFILEPATH = args.pubsfile
        pubsfilename = 'EcdsaPub.key'
        print("{}...".format(pubsfilename))
        if not PUBSFILEPATH:
            print("\tYou did not supply --pubsfile option... will look in cwd for file {}...".format(pubsfilename))
            PUBSFILEPATH = cwd + '/' + pubsfilename
        PUBSFILEPATH = os.path.abspath(PUBSFILEPATH)
        if not os.path.exists(PUBSFILEPATH):
            raise Exception("\nFile {} does not exist!  (Re-run with --pubsfile=<path to your licence file>, or, copy the file in to the directory you are running this script from".format(PUBSFILEPATH))
        print("\tfound {}".format(PUBSFILEPATH))

if __name__ == "__main__":

    init()

    #open connection
    CONN = _open_connection()

    if args.remove_vm:
        # in case they gave , sep l ist remove all those
        vms_to_remove = args.remove_vm.split(',')
        for vm in vms_to_remove:
            remove_vm(vm)

    # create num vms with these attributes
    vms = []
    if args.create_one_node_cluster:
        print("create a one node clusteR")
        #create_one_node_cluster(ram=int(args.ram), cores=int(args.cores))
        create_one_node_cluster()
        #make_vm_into_single_node_cluster()
        #sys.exit(0)

    # close connection
    _close_connection(CONN)
    '''
    if args.vms and not args.ssh:
        print("THey passed vms arg")
        for n in range(int(args.vms)):
            # createa  vm
            vms.append(create_vm(ram=int(args.ram), cores=int(args.cores)))

    # put the vms in to a cluster
    #cluster = create_cluster(nodes=vms, installdir=args.installer)
    '''


