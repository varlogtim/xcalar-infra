#!/usr/bin/env python
# -*- coding: utf-8 -*-

"""

Tool to spin up VMs on Ovirt and create Xcalar clusters

@examples

    python ovirttool.py --vms=1

        create single VM with all the defaults and Xcalar installed

    python overttool.py --vms=2 --noxcalar

        create two individual VMs with all defaults and no Xcalar installed

    python ovirttool.py --vms=2

        create two individual VMs with all the defaults an Xcalar installed

    python ovirttool.py --vms=2 --createcluster

        create VMs with default configurations and Xcalar installed; form in to cluster

    python ovirttool.py --vms=2 --ram=32 --cores=8 --createcluster --installer=<path on netstore to custom installer>

        Creates two node cluster with 32 GB ram and 8 cores, using a custom installer

"""

import ovirtsdk4 as sdk
import ovirtsdk4.types as types

import argparse
import getpass
import logging
import math
import multiprocessing
import os
import paramiko
import random
import requests
import shutil
import socket
import subprocess
import sys
import time
import urllib

logging.basicConfig(level=logging.DEBUG, filename='example.log')

MAX_VMS_ALLOWED=6

NETSTORE_IP='10.10.1.107'
XUID = '1001' # xcalar group uid. hacky fix later
JENKINS_USER_PASS = "jenkins" # password to set for user 'jenkins' on provisioned VMs

TMPDIR_LOCAL='/tmp/ovirt_tool' # tmp dir to create on local machine running python script, to hold pem cert for connecting to Ovirt
TMPDIR_VM='/tmp/ovirt_tool' # tmp dir to create on VMs to hold helper shell scripts, lic files (dont put timestamp because forking processes during install processing)
CLUSTER_DIR_VM='/mnt/xcalar' # if creating cluster of the VMs and need to mount netstore, will be local dir to create on VMs, to mount shared storage space to.

CONN=None
PUBSFILENAME='EcdsaPub.key'
LICFILENAME='XcalarLic.key'
# helper scripts - they should be located in dir this python script is at
INSTALLER_SH_SCRIPT = 'e2einstaller.sh'
TEMPLATE_HELPER_SH_SCRIPT = 'templatehelper.sh'
ADMIN_HELPER_SH_SCRIPT = 'setupadmin.sh'

CLUSTER_SUMMARY = None # if make a cluster will make a String with info about it to display in summary

FORCE = False # a force option will allow certain operations when script would fail otherwise (use arg)

class NoIpException(Exception):
    pass

'''
    OVIRT SDK FUNCTIONS
'''

'''
    Start a VM by given ID,
    and wait until it is up.
    if requested, wait until IP is generated
    and showing up in Ovirt

    :param vmid: unique id of VM (ovirtsdk4:types:Vm.id attr)
    :param waitForIP: (optional, False) don't return until IP assigned and displaying

    :returns: None

    :throws Exception if any stage not successfull
'''
def bring_up_vm(vmid, waitForIP=False):

    vm_service = get_vm_service(vmid)
    name = get_vm_name(vmid)

    if is_vm_up(vmid):
        # the api will throw exception if you try to start and it's in up state already
        print("Vm {} is already up!  I will not start".format(name), file=sys.stderr)
    else:
        print("\nStart service on {}".format(name), file=sys.stderr)
        timeout=60
        while True and timeout:
            try:
                # start the vm
                vm_service.start()
                print("started service!", file=sys.stderr)
                break
            except Exception as e:
                if 'VM is locked' in str(e):
                    time.sleep(10)
                    timeout-=1
                    print("vm is still locked; can't start service yet... try again...", file=sys.stderr)
                else:
                    # another exception don't know about - re-raise.  if the resource excpetion from Ovirt
                    # want to raise that will handle it higher up in the provision_vm function
                    if 'memory' in str(e):
                        print("Throwing memory exception: {}".format(str(e)), file=sys.stderr)
                    raise e
                        #raise Exception("Got another error I don't know about: {}".format(str(e)))
        if not timeout:
            raise Exception("Was never able to start service on {}!".format(name))

        print("\nWait for {} to come up".format(name), file=sys.stderr)
        timeout=120
        while True and timeout:
            if is_vm_up(vmid):
                print("\t{} is up!".format(name), file=sys.stderr)
                break
            else:
                time.sleep(5)
                timeout-=1
        if not timeout:
            raise Exception("Started service on {}, but VM never came up!".format(name))

    if waitForIP:
        print("\nWait until IP assigned and displaying for {}".format(name), file=sys.stderr)
        timeout=10
        while True and timeout:
            try:
                print("try to get vm ip", file=sys.stderr)
                ip = get_vm_ip(vmid)
                print("\tIP {} assigned to {}!".format(ip, name), file=sys.stderr)
                break
            except:
                # not available yet
                print("still no ip", file=sys.stderr)
                timeout -= 1
                time.sleep(5)
        if not timeout:
            raise NoIpException("Started service on {} and the VM came up, but never got IP (might increase timeout)".format(name))

'''
    Create a new vm and wait until you can get ip

    :param name: name of the new vm
    :param cluster: cluster in Ovirt should be hosted on
    :param template: name of template to use
    :param ram: (int) memory size (in bytes)
    :param cores: (int) num CPU on the VM

    :returns: (String) the unique Ovirt id generated for the new VM
'''
def create_vm(name, cluster, template, ram, cores):

    print("\nCreate a new VM called: {}\n\tOvirt cluster: {}\n\tTemplate VM  : {}\n\tRAM (bytes)  : {}\n\t# cores      : {}".format(name, cluster, template, ram, cores), file=sys.stderr)

    # Get the reference to the "vms" service:
    vms_service = CONN.system_service().vms_service()
    print("got vms service", file=sys.stderr)

    # create the VM Object and add to vms service
    # need a types:Cpu object to define cores
    vm_cpu_top = types.CpuTopology(cores=cores, sockets=1)
    vm_cpu = types.Cpu(topology=vm_cpu_top)
    newvmObj = types.Vm(
        name=name,
        cluster=types.Cluster(
            name=cluster,
        ),
        template=types.Template(
            name=template,
        ),
        memory=ram, # Ovirt SDK uses bytes!!
        cpu=vm_cpu,
    )
    vms_service.add(newvmObj)
    print("VM added...", file=sys.stderr)

    # get id of the newly added vm (can't get from obj you just created.  need to get from vms service)
    vmid = get_vm_id(name)
    print("\tid assigned: {}...".format(vmid), file=sys.stderr)

    # start vm and bring up until IP is displaying in Ovirt
    print("Bring up {}...".format(vmid), file=sys.stderr)
    # sometimes IP not coming up first time around.  restart and ty again
    tries = 5
    while True and tries:
        try:
            time.sleep(5)
            bring_up_vm(vmid, waitForIP=True)
            break
        except NoIpException:
            print("WARNING: Timed out waiting for IP on new VM... will restart and try again...", file=sys.stderr)
            tries -= 1
            stop_vm(vmid)
    if not tries:
        raise NoIpException("Never got Ip for {}/[id:{}],\neven after attempted restarts (dhcp issue?)".format(name, vmid))

    print("\nSuccessfully created VM {}, on {}!!".format(name, cluster), file=sys.stderr)
    #\n\tIP: {}\n\tCluster: {}\n\tTemplate {}".format(myvmname, new_ip, cluster, template))

    return vmid

'''
    Given a list of names of clusters to try and provision n VMs on,
    with ram bytes memory on each,
    Try to make a best guess if the cluster have enough available memory
    to handle creation of this VM request
    That way, we can skip provisioning and fail out if there's not enoug memory
    (Note - this is just a best guess.  Assumes you'd be attempting on clusters
    in order they appear in the list.)

    :param n (int): number of vms in request
    :param ram: (int) memory (in bytes) requested for each vm
    :param clusters: list of cluster names (Strings) of
        clusters you want to check, in the order you will be trying
        to provision them on

    :Returns:
        - if determined there is enoug memory:
            list of names of clusters from the list sent in, that could
            can create AT LEAST one VMs in the request
            (gives a way to avoid trying provisioning on clusters you know it's going to fail on)
        - False if determine not enough memory among all the clusters, to handle the vm request
'''
def enough_memory(n, ram, clusters):

    '''
        initialize request size at n (the number of VMs they want)
        go through list of clusters available.
        for each cluster, see how many VMs it would be able to provision.
        subtract that from request size. if request size still > 0,
        go to next cluster in list and do same.
        if get through list and request size still > 0, the VMs together were not (guessed) to eb able to handle the full request.
    '''
    useful_clusters = [] # keep track of those clusters able to provision at least 1 VM
    vms_remaining = n # start with the full # of Vms and see how many you think you could provision
    for i, cluster in enumerate(clusters):
        # see how much memory available in that cluster, and how many VMs it could provision based on
        mem_available_this_cluster = get_cluster_available_memory(cluster)
        print("{} bytes memory available on cluster {}".format(mem_available_this_cluster, cluster), file=sys.stderr)

        # see how many VMs you could make with that
        consumes = math.floor(mem_available_this_cluster/ram)
        print("{} vms could be consumed by cluster {}".format(consumes, cluster), file=sys.stderr)

        # if it couldn't create any VMs at all, don't include in list returned
        if consumes:
            print("Cluster {} could consume {} vms... add to useful clusters".format(cluster, consumes), file=sys.stderr)
            useful_clusters.append(cluster)

        # update how many VMs left in request.
        # if that takes care of rest of VMs, guess is that enough available memory!
        # return list of useful clusters!
        vms_remaining = vms_remaining - consumes
        print("{} would vms remain in request...".format(vms_remaining), file=sys.stderr)
        if vms_remaining <= 0:
            # add rest of the clusters in (no harm for more resources)
            print("Guess is clusters should be able to handle the VM request load (others could be using clusters though)", file=sys.stderr)
            useful_clusters = useful_clusters + clusters[i+1::]
            return useful_clusters

    if vms_remaining:
        return False

'''
    Determine the amount of available memory (in bytes) on a cluster

    :param name: (String) name of the Cluster as it appears in Ovirt

    :returns: (int) number of bytes of memory available across
        all hosts in the cluster
'''
def get_cluster_available_memory(name):

    '''
    types:Cluster objects don't seem to have types:Host for the hosts associated
    with (that i have found)
    so right now, go through each host, and see if it's in the cluster by name
    we're requesting
    '''

    mem_found = 0

    hosts_service = CONN.system_service().hosts_service()
    hosts = hosts_service.list()
    for host in hosts:
        if host.status != types.HostStatus.UP:
            print("Host {} is not UP.  Do not figure in to available memory estimates...".format(host.name), file=sys.stderr)
            continue

        if host.cluster:
            # cluster attr is a link.  follow link to retrieve data about the cluster
            cluster = CONN.follow_link(host.cluster)
            # try to get the name
            if cluster.name and cluster.name == name:
                print("Host {} is part of requested cluster, {}".format(host.name, cluster.name), file=sys.stderr)
                # add this hosts available memory to cnt
                if host.max_scheduling_memory:
                    print("Host {}'s max scheduling memory (in bytes): {}".format(host.name, str(host.max_scheduling_memory)), file=sys.stderr)
                    mem_found = mem_found + host.max_scheduling_memory

    print("Available memory found on cluster {}: {} bytes".format(name, mem_found), file=sys.stderr)
    return int(mem_found)

'''
    Generate n unique names currently not in use by any VMs in Ovirt
    Use convention: (1) find some base name, then (2) name vms
    <vm name>-0, <vm name>-1
    (so if they're wanting this for a cluster can put in cluster like that)

    :param n: number of unique names to generatecreate
    :param cluster: @TODO (check on each cluster?  diff clusters with same VM name?)
    :param user: Name of user (will put in String of VM names if supplied)
    :returns Str basevmname: the name all the vms arelist of unique names unused by any VMs on the cluster
'''
def generate_unused_vm_names(n, cluster, user=None):

    if n == 0:
        return []

    print("\nGenerate {} new vm names".format(str(n)), file=sys.stderr)

    # get the basename for the vm names
    basevmname = None
    tries = 50
    vmid = random.randint(1,200)
    basename = 'ovirt-tool-auto'
    if user:
        basename = basename + '-{}'.format(user)
    while True and tries:
        basevmname = '{}-{}'.format(basename, str(vmid))
        if get_matching_vms(basevmname):
            tries -= 1
            vmid += 1
        else:
            break
    if not tries:
        raise Exception("Need to delete some VMs to clear up resources:\n\tpython ovirttool.py --delete=" + myvmname)
    print("\nBasename: {}".format(basevmname), file=sys.stderr)

    # now base the others off that
    names = []
    for i in range(n):
        vmname = '{}-vm{}'.format(basevmname, str(i))
        if get_matching_vms(vmname):
            raise Exception("Didn't find any matching VMs by basename {}, "
                " but finding a matching vm with name {}!".format(basevmname, vmname))
        print("\n\tVM name: {}".format(vmname), file=sys.stderr)
        names.append(vmname)

    return basevmname, names

'''
    Given some identifier, such as an IP or the name of a VM,
    return list of VMs that match it.
    (This is equivalent to logging in to Ovirt, and typing
    the identifier string in the search bar, and returning a ovirtsdk4.type.Vm
    object for each matching row)

    :param identifier: String. search criteria you would type in the Ovirt search bar.

    :returns: list of ovirtsdk4.type.Vm objects, one for each
        vm matching the identifier string
        (if no matches returns empty list)
'''
def get_matching_vms(identifier):

    print("\nTry to find VMs matching identifier {}".format(identifier), file=sys.stderr)

    vms_service = CONN.system_service().vms_service()
    # search.  what you give as search is just like searching in the Ovirt search bar
    matching_vms = vms_service.list(search=identifier)
    if matching_vms:
        return matching_vms
    return []

'''
    Given some identifier, such as an IP or the name of a VM,
    return a VM which matches.

    :param identifier: search criteria you would type in the Ovirt search bar.
        YOu want to give something specific like an IP or the name ofyour VM

    :returns:
        unique VM id if 1 VM found
        None if no VM found

    :throws Exception if multiple matches (don't catch these for now)

'''
def get_vm_id(identifier):

    print("\nTry to find id of VM using identifier: {}".format(identifier), file=sys.stderr)
    matches = get_matching_vms(identifier)
    if matches:
        if len(matches) > 1:
            raise Exception("\nMore than one VM matched on identifier {}!  "
                " I can not find a unique VM id for this VM.  "
                "Be more specific".format(identifier))
        else:
            return matches[0].id

'''
    Get the IP for the VM needed for cluster creation
    Gets the IP on eth0 device

    :param vmid: unique id of VM in Ovirt to get IP of

    :returns: IP address if found
    :throws Exception: if no IP found
'''
def get_vm_ip(vmid):

    name = get_vm_name(vmid)
    print("\nGet IP of VM {}".format(name), file=sys.stderr)

    vm_service = get_vm_service(vmid)
    print("got vm service " + str(vm_service), file=sys.stderr)

    devices = vm_service.reported_devices_service().list()
    for device in devices:
        print("\tFound device: {}".format(device.name), file=sys.stderr)
        if device.name == 'eth0':
            ips = device.ips
            for ip in ips:
                # it will return mac address and ip address dont return mac address
                try:
                    socket.inet_aton(ip.address)
                    return ip.address
                except Exception as e:
                    print("\t(IP {} is probably a mac address; dont return this one".format(ip.address), file=sys.stderr)

    # never found!
    #return None
    raise Exception("Never found IP for vm: {}".format(name))

'''
    Given the unique VM id,
    return name of the VM.

    :param vmid: unique VM id (ovirtsdk4:type:Vm.id attr; not searchable in Ovirt)

    :returns: String name of the VM as it appears in Ovirt
'''
def get_vm_name(vmid):

    vms_service = CONN.system_service().vms_service()
    vm_service = vms_service.vm_service(vmid)
    if not vm_service:
        raise Exception("Couldn't retrieve vms service for vm of id: {}".format(vmid))
    vm_obj = vm_service.get()
    return vm_obj.name

'''
    Return an ovirtsdk4.services.VmsService object for VM
    of given id

    :param vmid: unique id of ovirtsdk4.type.Vm object for the vm

    :returns ovirtsdk4.services.VmsService object for that VM

    :throws Exception if no VM existing by that id

'''
def get_vm_service(vmid):

    # Locate the service that manages the virtual machine, as that is where
    # the action methods are defined:
    vms_service = CONN.system_service().vms_service()
    vm_service = vms_service.vm_service(vmid)
    if not vm_service:
        print("Could not locate a vm service for vm id {}".format(vmid), file=sys.stderr)
    return vm_service

'''
    Check if vm of given name (id) is in an up state

    :param name: name of vm to check state of

    :returns: boolean indicating if in UP state or not
'''
def is_vm_up(vmid):

    vm_service = get_vm_service(vmid)
    vm = vm_service.get()
    if vm.status == types.VmStatus.UP:
        return True
    else:
        print("VM status: {}".format(vm.status), file=sys.stderr)
    return False

'''
    Return list of names of all vms available to vms
'''
def get_all_vms():

    vms_service = CONN.system_service().vms_service()
    vms = vms_service.list()
    vm_names = []
    for vm in vms:
        vm_names.append(vm.name)
    return vm_names

'''
    Remove a vm of a given name.
    Return True on successfull removal
    If VM does not exist returns None

    :param identifier: (String) an identified you could type in Ovirt search
        for the VM you want to remove.  Such as, an IP of the VM's name
    :param releaseIP: (Optional)
        If True will SSH in to VM and release IP before removal.
        If IP is powered off will power on first.
        (Can set this to False if you want to proceed quicker and not worried
        about running out of IPs.)
'''
def remove_vm(identifier, releaseIP=True):

    print("\nTry to Remove VM {} from Ovirt\n".format(identifier), file=sys.stderr)
    # try to get the vm to remove...
    vmid = get_vm_id(identifier)
    if not vmid:
        print("No VM found to remove, using identifier : {}".format(identifier), file=sys.stderr)
        raise Exception("Could not remove vm of identifier: {}.  VM does not return from search!".format(identifier))
    name = get_vm_name(vmid)

    vm_service = get_vm_service(vmid)
    print("got service", file=sys.stderr)

    if releaseIP:
        '''
            Want to release IP before removal.
            Need VM to be up to get IP.
            If VM down bring up so can get IP.
            Then SSH and release the IP
        '''
        print("Attempt to release ip before removing {}".format(name), file=sys.stderr)

        if not is_vm_up(vmid):
            print("\nBring up {} so can get IP...".format(name), file=sys.stderr)
            bring_up_vm(vmid, waitForIP=True)

        # if vm up, wait until ip displaying in case
        # this is a vm that was just created and we tried to
        # remove right away
        timeout = 10
        while True and timeout:
            try:
                ip = get_vm_ip(vmid)
                # dev check -it should be throwing exception if can't find
                # if switched to returning None need to update logic
                if ip is None:
                    print("\nError!  get_vm_ip was raising exception when can't find ip"
                        " now returning None.  Please sync code", file=sys.stderr)
                    sys.exit(1)
                break
            except:
                time.sleep(5)
                timeout -= 1

        '''
            sometimes the IP is not coming up.
            This seems to happen on new VMs that had an issue
            coming up initially.
            So if timed out here,
            just skip getting the IP.  power down and remove like normal
        '''
        if timeout:
            vm_ip = get_vm_ip(vmid)
            print("\nFound IP of VM... Release IP {}".format(vm_ip), file=sys.stderr)
            cmds = [['dhclient -v -r']] # assuming Centos7... @TODO for other cases?
            run_ssh_cmds(vm_ip, cmds)
        else:
            print("\nWARNING: I could still never get an IP for {}, "
                " even though it shows as up,"
                " will just shut down and remove VM without IP release".format(name), file=sys.stderr)
            #raise Exception("Never found IP for {}, even though it shows as up".format(name))

    # must power down before removal
    if is_vm_up(vmid):

        print("\nStop VM {}".format(name), file=sys.stderr)
        timeout=60
        while True and timeout:
            try:
                vm_service.stop()
                break
            except Exception as e:
                timeout-=1
                time.sleep(5)
                print("still getting an exception...." + str(e), file=sys.stderr)
        if not timeout:
            raise Exception("Couldn't stop VM {}".format(name))

        timeout=60
        print("\nWait for service to come down", file=sys.stderr)
        while True and timeout:
            vm = vm_service.get()
            if vm.status == types.VmStatus.DOWN:
                print("vm status: down!", file=sys.stderr)
                break
            else:
                timeout -= 1
                time.sleep(5)
        if not timeout:
            raise Exception("Stopped VM {}, but service never came donw".format(name))

    print("\nRemove VM {} from Ovirt".format(name), file=sys.stderr)
    timeout = 5
    while True and timeout:
        try:
            vm_service.remove()
            break
        except Exception as e:
            time.sleep(5)
            if 'is running' in str(e):
                print("vm still running... try again...", file=sys.stderr)
            else:
                raise SystemExit("unexepcted error when trying to remve vm, {}".format(str(e)))
    if not timeout:
        raise Exception("Stopped VM {} and service came down, but could not remove from service".format(name))

    print("\nWait for VM to be gone from vms service...", file=sys.stderr)
    timeout = 20
    while True and timeout:
        try:
            match = get_vm_id(name)
            print("Vm still exist...", file=sys.stderr)
            # dev check: make sure that function didn't change from throwing exception
            # to returning None
            if not match:
                raise Exception("Logic error: get_vm_id was throwing Exception on not being able to find"
                    " vm of given identifier, now it's returning None.  Please sync code")
            time.sleep(5)
            timeout -= 1
        except:
            print("VM {} no longer exists to vms".format(name), file=sys.stderr)
            break
    if not timeout:
        raise Exception("Stopped VM {} and service came down and removed from service, "
            " but still getting a matching id for this vm!".format(name))

    print("\n\nSuccessfully removed VM: {}".format(name), file=sys.stderr)

'''
    remove VMs from ovirt in parallel processes
    (if vm is when trying to remove, will have to power up to get ip to release.
    so if there's a lot of vms thsi could take some time.
    so run parallel processes.

    :param vms: list of vm 'identifiers'
        Some string which should identify the VM, such as an IP or name
        (same as if you typed the String in the search bar in Ovirt GUI)
        (a String that would give mu ltiple results, won't delete those VMs)
'''
def remove_vms(vms, releaseIP=True):

    print("Remove VMs {} in parallel".format(vms), file=sys.stderr)

    procs = []
    badvmidentifiers = []
    for vm in vms:
        if get_matching_vms(vm):
            proc = multiprocessing.Process(target=remove_vm, args=(vm,), kwargs={'releaseIP':releaseIP})
            time.sleep(5)
            proc.start()
            procs.append(proc)
        else:
            badvmidentifiers.append(vm)

    # wait for the processes
    process_wait(procs)

    if badvmidentifiers:
        vm_list = get_all_vms()
        valid_vms = "\n\t".join(vm_list)
        err = "\n\nYou supplied some invalid VMs to remove.\nValid VMs:\n\n\t{}".format(valid_vms)
        err = err + "\n\nCould not find matches in Ovirt for following VMs: {}.  See list above for valid VMs\n".format(",".join(badvmidentifiers))
        print(err, file=sys.stderr)
        sys.exit(1)

'''
    stop vm and wait for status to be down

    :param vmid: unique id of vm in Ovirt (id attr of type:Vm object)

    :returns True once vm stopped
    :raises Exception if times out
'''
def stop_vm(vmid, timeout=50):

    vms_service = CONN.system_service().vms_service()
    vm_service = vms_service.vm_service(vmid)

    vm = vm_service.get()
    if vm.status == types.VmStatus.DOWN:
        print("VM is already down!  No need to stop...", file=sys.stderr)
        return True

    # Call the "stop" method of the service to stop it:
    vm_service.stop()

    # Wait till the virtual machine is down:
    while True and timeout:
        time.sleep(5)
        vm = vm_service.get()
        if vm.status == types.VmStatus.DOWN:
            print("VM is now down....", file=sys.stderr)
            return True
        else:
            timeout -= 1

    if not timeout:
        raise Exception("Timed out waiting for VM to come down")

'''
    Open connection to Ovirt engine.
    (sdk advises to free up this resource when possible)

    :returns: ovirtsdk4:Connection object
'''
def open_connection(user=None):

    print("\nOpen connection to Ovirt engine...", file=sys.stderr)

    # get username if user didn't supply when calling script
    if not user:
        # get user name
        user = input('Username: ')
    # if they gave the full thing just get the uname part
    if '@' in user:
        user = user.split('@')[0]

    # determine username to send to Ovirt
    # (user accounts are on the profile1 Profile,
    # admin is on the internal Profile)
    if user == 'admin':
        user = 'admin@internal'
    else:
        user = user + '@xcalar.com@profile1'

    # promopt user for pass
    password=None
    passenv="OVIRT_PASSWORD"
    if passenv in os.environ:
        password=os.environ.get(passenv)
    else:
        try:
            password = getpass.getpass()
        except Exception as err:
            print("Error:", err, file=sys.stderr)

    # get the pem certification
    certpath = get_pem_cert()

    # set up connection
    conn = sdk.Connection(
        url='https://ovirt.int.xcalar.com/ovirt-engine/api',
        username=user,
        password=password,
        debug=True,
        ca_file=certpath,
        log=logging.getLogger(),
    )

    return conn

'''
    Close connection to Ovirt enginer

    :param conn: :ovirtsdk4:Connection object to close connection on
'''
def close_connection(conn):

    print("close connection to ovirt engine...", file=sys.stderr)

    if conn:
        conn.close()
    else:
        raise Exception("Trying to close a null connection")

'''
    returns path on local machine executing this script,
    to a cert to use for connecting to Ovirt.

    :args None:

    :returns Str filepath to pem cert on local machine executing scriput,
        to use when connecting to Ovirt server

'''
def get_pem_cert():

    # get the pem cert from netstore
    response = requests.get('http://netstore/infra/ovirt/ovirt.int.xcalar.com.pem')
    #print(response.text)
    # save in a tmp file and return that
    tmpfilename = 'ctmp.pem'
    if not os.path.isdir(TMPDIR_LOCAL):
        os.makedirs(TMPDIR_LOCAL)
    tmpfilepath = TMPDIR_LOCAL + '/' + tmpfilename
    pemfile = open(tmpfilepath, 'w')
    pemfile.write(response.text)
    pemfile.close()
    return tmpfilepath

'''
    Attempt to provision a vm
    Set jenkins user password to jenkins on the new VM

    :param name: name of vm
    :param ram: (int) memory (in bytes)
    :param cores: (int) number of cores
    :param availableClusters: (list of Strings of names of clusters)
        if fail to make on one of the clusters, try on the others
'''
def provision_vm(name, ram, cores, availableClusters):

    print("\nTry to provision VM {} on one of the following clusters: {}".format(name, availableClusters), file=sys.stderr)

    for orderedcluster in availableClusters:
        template = get_template(orderedcluster)
        try:
            vmid = create_vm(name, orderedcluster, template, ram, cores)

            if not vmid:
                raise Exception("Ovirt seems to have successfully created VM {}, but no id generated".format(name))

            # set jenkins password before returning
            # do here instead of during installation in case they don't want to install xcalar
            ip = get_vm_ip(vmid)
            print("Change password for user 'jenkins' on {} ({})".format(name, ip), file=sys.stderr)
            run_ssh_cmd(ip, 'echo "jenkins:{}" | chpasswd'.format(JENKINS_USER_PASS))

            return True
        #except ResourceException as err:
        except Exception as e:
            if 'available memory is too low' in str(e):
                print("Hit memory error!! :"
                    " Not enough memory on {} to create requested VM"
                    "\nTry to delete it and try on next cluster (if any)...".format(orderedcluster), file=sys.stderr)
                remove_vm(name, releaseIP=False) # set releaseIP as False - else, it's going to try and bring the VM up again to get the IP! and will fail for same reason
            else:
                print("VM provisioning failed for a reason other than memory too low", file=sys.stderr)
                raise e
                #raise Exception("Failed for another reason!: {}".format(str(e)))

    # hit this problem in all of them
    errMsg = '''Error!! There are not enough resources available to provision the next VM
         of {} bytes RAM, {} cores
        \nTried on clusters: {}'''.format(ram, cores, availableClusters)
    print(errMsg, file=sys.stderr)
    sys.exit(1) # do a sys exit instead of raising exception because then this process will terminate
    # elses if its being called as a subprocess you're going to have to wait for it to time out
    #raise Exception(errMsg)

'''
    provisions n vms in parallel.
    waits for all vms to come up with ips displaying
    Return a list of names of vms created in Ovirt

    :param n: (int) number of VMs to create
    :param ovirtnode: which cluster in Ovirt to create VMs from
    :param ram: (int) memory (in GB) on each VM
    :param cores: (int) num cores on each VM
    :param user: (optional String) name of user.  if given will include in the new VM names

    :returns: list of unique vm ids for each VM created
        (this is distinct from name; its id attr of Type:Vm Object)

'''
def provision_vms(n, ovirtnode, ram, cores, user=None, tryotherclusters=True):

    if n == 0:
        return None

    if not ram or not cores:
        raise Exception("Value error when calling provision_vms"
            " (perhaps default values changed for the --ram or --cores options")

    print("\nProvision {} vms on ovirt node {}\n".format(n, ovirtnode), file=sys.stderr)

    '''
        get list of cluster we can try to provision the VMs on.
        (if tryotherclusters is True, then can try on other clusters
        other than one specified by ovirtnode param, in case something
        goes wrong on that cluster)
    '''
    availableClusters = [ovirtnode]
    if tryotherclusters:
        availableClusters = get_cluster_priority(prioritize=ovirtnode)
    print("\nClusters available to provision the vms on: {}".format(availableClusters), file=sys.stderr)

    # will check for memory constraints and fail script if determined we can't handle the VM request.
    # bypass if force specified and try to provision anyway
    if not FORCE:
        '''
            Before attempting to provision the VMs, make a best guess
            if there is enough memory available amongst the clusters
            for provisioning all of the requested VMs,
            so can fail quickly if not and not.
            ('enough_memory' function, if it guesses that it's possible to handle the VM request,
            will return filtered list - those clusters of the clusters passed in,
            which can provision at least 1 VM in the request.
            this way skip trying on clusters you know it's going to fail on.)
        '''
        print("\nCheck first if enough memory available...", file=sys.stderr)
        fullClusList = availableClusters # if fail want to print out the original list of clusters in err message
        availableClusters = enough_memory(n, ram, availableClusters)
        print("\nClusters determined we can use: {}".format(str(availableClusters)), file=sys.stderr)
        if not availableClusters:
            err = "\n\nError: There is not enough memory on cluster(s) {}, to provision the requested VMs".format(fullClusList)
            err = err + "\nTry to free up memory on the cluster(s)."
            if not tryotherclusters:
                err = err + "\nYou can also run this tool with --tryotherclusters option, to make other clusters available to you during provisioning"
            err = err + "\nTo ignore this error and try to provision anyway, re-run with --f option\n"
            print(err, file=sys.stderr)
            sys.exit(1)

    '''
        get n new names for the vms
        (doing outside for loop avoids naming collision
        if we start processes
        quickly and looks like a VM by a given ID doesn't exist
        yet so assigned that name, but really its just that the VM
        isn't up yet in the sibling process.)
    '''
    basename, vm_names = generate_unused_vm_names(n, ovirtnode, user=user)
    procs = []
    sleepBetween = 20
    for newvm in vm_names:
        print("\nFork new process to create a new VM by name {}".format(newvm), file=sys.stderr)
        proc = multiprocessing.Process(target=provision_vm, args=(newvm, ram, cores, availableClusters))
        #proc = multiprocessing.Process(target=create_vm, args=(newvm, ovirtnode, template, ram, cores)) # 'cluster' here refers to cluster the VM is on in Ovirt
        # it will fail if you try to create VMs at exact same time so sleep
        time.sleep(sleepBetween)
        proc.start()
        procs.append(proc)

    # wait for the processes
    process_wait(procs, timeout=500+sleepBetween*len(vm_names))

    # get the list of the unique vm ids
    # a good check to make sure these VMs actually existing by these names now
    ids = []
    for vm in vm_names:
        ids.append(get_vm_id(vm))
    #return vm_names
    return basename, ids

'''
    @todo
'''
def is_xcalar_running(node):

    print("\nCheck if Xcalar is running", file=sys.stderr)

'''
    Bring up Xcalar service on node

    :param node: ip of node to start Xcalar service on
'''
def start_xcalar(node):

    print("\nStart Xcalar service on node {}\n".format(node), file=sys.stderr)
    cmds = [['service xcalar start', 600]]
    run_ssh_cmds(node, cmds)

'''
    Bring down Xcalar service on node

    :paran node: ip of node to stop xcalar service on
'''
def stop_xcalar(node):

    print("\nStop Xcalar service on node {}\n".format(node), file=sys.stderr)
    cmds = [['service xcalar stop', 120]]
    run_ssh_cmds(node, cmds)

'''
    Copy necessary Xcalar license files on to a remote node
    @node: IP of node to copy files on to
'''
def copy_lic_files(node, dest='/etc/xcalar'):

    print("\nCopy Xcalar license files in to {}\n".format(node), file=sys.stderr)

    '''
         scp in the license files in to the VM
    '''
    files = [LICFILEPATH, PUBSFILEPATH]
    for licfile in files:
        print("dest: " + dest, file=sys.stderr)
        print("node: " + node, file=sys.stderr)
        print("lic file: " + licfile, file=sys.stderr)
        scp_file(node, licfile, dest)

'''
    Bring up xcalar service on a node and setup admin account

    :param node: ip of node to setup admin account on
'''
def setup_admin_account(node):

    print("\nSetup admin account on {}\n".format(node), file=sys.stderr)

    # the script calls the Xcalar API and xcalar service needs to be started for it to work
    start_xcalar(node)

    # there's a shell script for that...
    scp_file(node, ADMIN_HELPER_SH_SCRIPT, TMPDIR_VM)
    # run the helper script
    run_sh_script(node, TMPDIR_VM + '/' + ADMIN_HELPER_SH_SCRIPT)

'''
    Install xcalar on VM of given id
    Copy in helper shell scripts used for instlalation
    start service if requested

    :param vmname: name of VM (vm id) in Ovirt to install Xcalar on
    :param licfilepath: path on local machine runnign this script, of Xcalar license file
    :param pubsfilepath: path on local machine running this script, of pubs file
    :param installerpath: path on Netstore, of installer to use

'''
def setup_xcalar(ip, licfilepath, pubsfilepath, installerpath):

    vmname = get_vm_name(get_vm_id(ip))

    print("\nInstall Xcalar on {} (IP: {}), using RPM installer:\n\t{}\n".format(vmname, ip, installerpath), file=sys.stderr)

    '''
        There is an end-to-end shell script whicho will
        do install, generate template file, put lic files in right dir, etc.
        create a tmpdir and copy in that helper shell script,
        along with dependencies.
    '''

    # create tmp dir to hold the files
    run_ssh_cmd(ip, 'mkdir -p {}'.format(TMPDIR_VM))

    # copy in installer shell script and files it depends on
    fileslist = [[INSTALLER_SH_SCRIPT, TMPDIR_VM],
        [TEMPLATE_HELPER_SH_SCRIPT, TMPDIR_VM], # installer script will call this template helper script
        [pubsfilepath, TMPDIR_VM + '/' + PUBSFILENAME], # installer script assumes the lic files are in same dir.
            # rename lic files to std name in case they supplied a file with a diff name, because e2e script will call by st name
        [licfilepath, TMPDIR_VM + '/' + LICFILENAME]]
    for filedata in fileslist:
        scp_file(ip, filedata[0], filedata[1])

    # install using bld requested
    run_sh_script(ip, TMPDIR_VM + '/' + INSTALLER_SH_SCRIPT, args=[installerpath, vmname, ip], timeout=1000)

'''
    Install and setup Xcalar on a set of nodes.
    Once xcalar installation completes on all of them,
    form in to a cluster unless specified otherwise

    :param vmids: list of unique vm ids in Ovirt of VMs to install xcalar on
    :param licfilepath: path to License file on local machine executing this script
    :param pubsfilepath: "" "" pubs file ""
    :param createcluster: (optional) If supplied, will form the nodes in to cluster once Xcalar installed
        If not supplied will leave nodes as individual VMs

    :returns None:

'''
def initialize_xcalar(vmids, licfilepath, pubsfilepath, installerpath, createcluster=None):

    print("\nSetup xcalar on node set and cluster {}".format(createcluster), file=sys.stderr)

    procs = []
    ips = []

    sleepBetween = 15
    for vmid in vmids:
        # get ip
        ip = get_vm_ip(vmid)
        name = get_vm_name(vmid)
        ips.append(ip)
        print("\nStart new process to setup xcalar on {}, {}".format(name, ip), file=sys.stderr)
        proc = multiprocessing.Process(target=setup_xcalar, args=(ip, licfilepath, pubsfilepath, installerpath))
        # failing if i dont sleep in between.  think it might just be on when using the SDK, similar operations on the vms service
        time.sleep(sleepBetween)
        procs.append(proc)
        proc.start()

    # wait
    process_wait(procs, timeout=500+sleepBetween*len(vmids))

    # form the nodes in to a cluster if requested
    if createcluster and len(ips) > 1:
        create_cluster(ips, createcluster)

    '''
        power up all the nodes in parallel and set up admin accounts
        doing here instead of in initial setup, so that you don't have
        to bring up Xcalar more than once in the case of cluster creating.
        (setting up admin requires bringing up xcalar and so does cluster
        creating so do at very end for both cluster and non-cluster scen.)
    '''
    procs = []
    sleepBetween = 20
    for ip in ips:
        proc = multiprocessing.Process(target=setup_admin_account, args=(ip,)) # need comma because 1-el tuple
        time.sleep(sleepBetween)
        procs.append(proc)
        proc.start()

    # wait for all the processes to complete successfully
    process_wait(procs, timeout=400+sleepBetween*len(ips))

'''
        FOR CLUSTER SETUP
'''

'''
    Given a list of node IPs, create a shared space for those
    nodes, and form the nodes in to a cluster.

    :param nodeips: list of IPs of the nodes you want made in to a cluster
    :param clustername: name you want the cluster to be
        (will be dir name of shared storage space)
'''
def create_cluster(nodeips, clustername, start=True):

    if not len(nodeips):
        raise Exception("No nodes to make cluster on!")

    '''
        Create a shared storage space for the nodes
        on netstore, using cluster name
    '''
    sharedRemoteStoragePath = 'ovirtgen/' + clustername
    create_cluster_dir(sharedRemoteStoragePath)

    # for each node, generate config file with the nodelist
    # and then bring up the xcalar service
    print("\nCreate cluster using nodes : {}".format(nodeips), file=sys.stderr)
    procs = []
    for ip in nodeips:
        print("\n\tFork cluster config for {}\n".format(ip), file=sys.stderr)
        '''
        Note: The order of the ips in nodeips list is important!!
        Will be node 0 (root cluster node), node1, etc., in order of list
        '''
        proc = multiprocessing.Process(target=configure_cluster_node, args=(ip, nodeips, sharedRemoteStoragePath))
        time.sleep(15)
        procs.append(proc)
        proc.start()

    # wait for all the proceses to complte
    process_wait(procs)

    # helpful display string to put in summary
    # this a temporary hack for end of script summary; should get this info live at end to display
    global CLUSTER_SUMMARY
    CLUSTER_SUMMARY = cluster_summary_str(nodeips[0], clustername, 'xdpadmin', 'Welcome1', nodeips)

'''
    Create a dir on netstore by the cluster name
    Set owner to Xcalar uuid
    Create a /config dir in the shared storage space and also
    set its owner to xcalar (this is where cfg data gets written to)

    :param remotePath: path on netstore to use as cluster dir
'''
def create_cluster_dir(remotePath):

    # create a dir on netstore, name after root node
    # do it on netstore
    cmds = ['sudo mkdir -p /netstore/' + remotePath,
            'sudo chown ' + XUID + ':' + XUID + ' /netstore/' + remotePath]
    #cmds = [['sudo mkdir -p /netstore/{}/config'.format(remotePath)],
    #        ['sudo chown ' + XUID + ':' + XUID  + ' /netstore/' + remotePath],
    #        ['sudo chown ' + XUID + ':' + XUID  + ' /netstore/' + remotePath + '/config']]
    for cmd in cmds:
        run_system_cmd(cmd)
        #print("System command:: {}".format(cmd), file=sys.stderr)
        #os.system(cmd)

'''
    Configure a node to be part of a cluster
    by generating its default.cfg with a nodelist,
    and bringing up the node

    :param node: ip of node
    :param clusternodes: list of IPs of all the nodes in the cluster
        ORDER OF THIS LIST IS IMPORTANT.
        clusternodes[0] : root node (node 0)
        clusternodes[1] : node1
        ... etc
    :param remoteClusterStoragePath: remote path on netstore that acts as shared storage for the nodes

'''
def configure_cluster_node(node, clusternodes, remoteClusterStoragePath):

    print("\nConfigure cluster node of {} of cluster nodes: {}\n".format(node, clusternodes), file=sys.stderr)

    print("get local path to shared storage {}".format(remoteClusterStoragePath), file=sys.stderr)
    local_cluster_storage_dir = setup_cluster_storage(node, remoteClusterStoragePath)
    #mount_shared_cluster_storage(node, remoteClusterStoragePath, CLUSTER_DIR_VM)

    print("generate cluster template file...", file=sys.stderr)
    generate_cluster_template_file(node, clusternodes, local_cluster_storage_dir)

'''
    Generate template file for node
    (/etc/xcalar/default.cfg file, on the node)

    :param node: ip of node to generate cfg file for
    :clusternodes: list of Strings: list of ips of nodes in the cluster
        ORDER IS IMPORTANT
        clusternodes[0] : root node (node 0)
        clusternodes[1] : node1
        ... etc  <that's how the shell script being called should work>
    :param xcalarRoot: local path on the node to shared storage
        (val you want for Constants.XcalarRootCompletePath in the cg file)
'''
def generate_cluster_template_file(node, clusternodes, xcalarRoot):

    print("\nGenerate /etc/xcalar/default.cfg file for node {}, set with cluster nodes {}\n".format(node, clusternodes), file=sys.stderr)

    # there's a shell script for that
    nodeliststr = ' '.join(clusternodes)
    #scp_file(node, TEMPLATE_HELPER_SH_SCRIPT, TMPDIR_VM) # the e2e installer needs this script too so if it's not present I want this to fail
    # so don't copy it in
    run_sh_script(node, TMPDIR_VM + '/' + TEMPLATE_HELPER_SH_SCRIPT, args=[xcalarRoot, nodeliststr])

'''
    Given a node IP and path to remote storage on netstore,
    setup the node to have access to that directory.
    check if netstore is mounted on the node, and it not mount it

    :paran node: (String) IP of the node to set shared storage on
    :param remotePath: (String) path on netstore to shared storage

    :returns: (String) local path on the node, to access the
        shared netstore storage
'''
def setup_cluster_storage(node, remotePath):

    print("\nDetermine local path VM {} should use to for xcalar home "
        " (Constants.XcalarRootCompletePath var in  /etc/xcalar/default.cfg".format(node), file=sys.stderr)
    localPath = None

    '''
        Check if netstore already mounted on the VM.
        If so, local patha lready exists.
    '''
    alreadyMountedCheckPath = "/netstore/" + remotePath
    if path_exists_on_node(node, alreadyMountedCheckPath):
        print("Netstore already mounted... use {} as local path to shared storage".format(alreadyMountedCheckPath), file=sys.stderr)
        return alreadyMountedCheckPath
    # netstore is not mounted.
    # mount and return the local path that results.
    # please try a couple times the mount command, it fails periodically
    localPath = CLUSTER_DIR_VM
    tries = 5
    print("Netstore not yet mounted on this vm", file=sys.stderr)
    while True and tries:
        try:
            mount_shared_cluster_storage(node, remotePath, localPath)
        except:
            print("Hit an issue when trying to mount netstore on vm... try again", file=sys.stderr)
            time.sleep(5)
            tries -= 1
    if not tries:
        raise Exception("I was not able to mount netstore on node {}; "
            " i kept hitting an exception".format(node))

    # regardless which path you went down... make sure it exists now on the VM!
    if path_exists_on_node(node, localPath):
        return localPath

'''
    Mount a directory on Netstore provisioned for shared cluster storage,
    on a cluster node.

    :param node: IP of node to mount the storage space on
    :param remotePath: Path on netstore, to remote shared storage space

'''
def mount_shared_cluster_storage(node, remotePath, localPath):

    print("\nMount remote Netstore dir {} on node {} as shared storage,"
        " at {}\n".format(remotePath, node, localPath), file=sys.stderr)

    '''
        Check if netstore already mounted on the VM.
        If so do not need to mount.
    '''

    cmds = [['mkdir -p ' + localPath + '; mount -t nfs  ' + NETSTORE_IP + ':/mnt/public/netstore/' + remotePath + ' ' + localPath + '; chown ' + XUID + ':' + XUID + ' ' + localPath, 60]]
    run_ssh_cmds(node, cmds)

'''
    Check if a path exists on a node
    by SSHing and trying to cd to that path

    :param node: ip of node to check path on
    :param path: path to check on the node
'''
def path_exists_on_node(node, path):

    tries=25
    while True and tries:
        try:
            status = run_ssh_cmd(node, 'ls ' + path, timeout=10)
            #status = run_ssh_cmd(node, 'cd ' + path, timeout=10)
            if status:
                print("Got non-0 status when trying to cd to {}..  doesn't exist?".format(path), file=sys.stderr)
                return False
            return True
        except Exception as e:
            print("Hit an exception trying to ls to {} (netstore) on {}... Will try again in case automount issue...".format(path, node), file=sys.stderr)
            tries -= 1
            time.sleep(5)

    if not timeout:
        print("Timed out trying to cd to netstore, I tried multiple times", file=sys.stderr)
        sys.exit(1)

'''
    get priority of clusters to try.
    Can pass an optional arg that will force a particular cluster
    to front of priority list.
    if that cluster is not valid will raise exception
'''
def get_cluster_priority(prioritize=None):

    # try the clusters in this order
    clusterPriority = ['node3-cluster', 'node2-cluster', 'node4-cluster', 'node1-cluster']
    validClusters = []
    mapping = get_template_mapping() # get the official template mapping
    if prioritize:
        if prioritize in mapping:
            validClusters.append(prioritize)
        else:
            raise Exception("Trying to prioritize {} but not a valid cluster".format(prioritize))
    for orderedcluster in clusterPriority:
        if orderedcluster != prioritize and orderedcluster in mapping:
            validClusters.append(orderedcluster)
    return validClusters

def get_template_mapping():

    return {
        #'node1-cluster': {'Blank'},
        'node2-cluster': 'ovirt-cli-tool-node2-template',
        'node3-cluster': 'ovirt-cli-tool-node3-template',
        'node4-cluster': 'ovirt-cli-tool-node4-template',
    }

'''
    Return name of template and cluster template is on,
    depending on what args requestesd (RAM, num cores, etc.)
'''
def get_template(ovirtnode):

    '''
    @TODO:
        Select the template based on their preferences
        of RAM, etc.
        For now, just base on the node specified,
        or if no node use node4
    '''
    template_mapping = get_template_mapping()

    # make so the value is a hash with keys for RAM, cores, etc.
    #and appropriate template for now just one std template each
    # check that the node arg a valid option
    if ovirtnode in template_mapping.keys():
        ## todo - there should be templates for all the possible ram/cores/etc configs
        return template_mapping[ovirtnode]
    else:
        raise Exception("\n\nNo template found to use on ovirt node {}."
            "\nValid nodes with templates: {}".format(ovirtnode, ",".join(template_mapping.keys())))

'''
        SYSTEM COMMANDS
'''


'''
    scp a file from the local machine to a remove machine
    @node ip of remote machine to copy file on to
    @localfilepath filepath of the file on the local machine
    @remotefilepath filepath where to put the file on the remote machine
'''
def scp_file(node, localfilepath, remotefilepath):

    print("\nSCP: Copy file {} from host, to {}:{}".format(localfilepath, node, remotefilepath), file=sys.stderr)

    cmd = 'scp -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no ' + localfilepath + ' root@' + node + ':' + remotefilepath
    run_system_cmd(cmd)

def run_ssh_cmds(host, cmds):

    print("\nTry ssh root@{} ...\n\n".format(host), file=sys.stderr)

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
    print("\n~ Will try to 'ssh {}@{}' .. ".format(user, host), file=sys.stderr)
    client = paramiko.SSHClient()
    print("\tD: Made Client obj...", file=sys.stderr)
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print("\tD: try to connect on port {}".format(port), file=sys.stderr)
    client.connect(hostname=host, port=port, username=user)#, key_filename=key_filename, banner_timeout=10)
    print("\tconnected to : {}".format(host), file=sys.stderr)
    chan = client.get_transport().open_session()
    print("\tOpened session...", file=sys.stderr)
    chan.settimeout(timeout)
    print("\tD: set timeout to {}".format(timeout), file=sys.stderr)
    chan.set_combine_stderr(True)
    print("\tD: chan3", file=sys.stderr)
    chan.get_pty()
    print("\t\t~~ SEND CMD: {}".format(command), file=sys.stderr)
    print("[" + user + "@" + host +  "] " + command, file=sys.stderr)
    chan.exec_command(command)
    print("\t\t\tD: success", file=sys.stderr)
    stdout = chan.makefile('r', bufsize)
    print("\tReading stdout ...", file=sys.stderr)
    print("\t\t\tD: made a file", file=sys.stderr)
    stdout_text = stdout.read()
    print("\t\t\tstdout: {}".format(stdout_text), file=sys.stderr)
    status = int(chan.recv_exit_status())
    print("\t\t\tstatus: {}".format(status), file=sys.stderr)
    if status:
        print("stdout text:\n{}\n\nI encountered a non-0 exit status when running SSH cmd {} on host {}!  (See above stdout)".format(stdout_text, command, host), file=sys.stderr)
        sys.exit(status)
    client.close()
    print("\tclosed client connection", file=sys.stderr)
    return status

'''
    run system command on local machine calling this function

    (i've made this in to a function because there's a better way
    in python to be making system calls than os.system; i will
    look that up.  but when i determine that i can just change
    in one place.  i can take this out later.)
'''
def run_system_cmd(cmd):

    # subprocess.check_output always throws CalledProcessError for non-0 status
    try:
        #cmdout = subprocess.run(cmd, shell=True)
        cmdout = subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True)
    except subprocess.CalledProcessError as e:
        print("Stderr: {}\n\nGot error when running sys command {}:\n{}".format(str(e.stderr), cmd, str(e.output)), file=sys.stderr) # str on output in case None
        sys.exit(e.returncode)

    '''
    print("~:$ {}".format(cmd), file=sys.stderr)
    os.system(cmd)
    '''

'''
    Run a shell script on a node

    :param node: IP of node to run shell script on
    :param path: filepath (on node) of shell script
    :param args: list of positional args to supply to shell script

'''
def run_sh_script(node, path, args=[], timeout=120, tee=False):

    print("\nRun shell script {} on node {}...\n".format(path, node), file=sys.stderr)

    shellCmd = '/bin/bash ' + path + ' ' + ' '.join(args)
    if tee:
        filename = os.path.basename(path)
        shellCmd = shellCmd + ' | tee ' + filename + 'log.log'
    cmds = [['chmod u+x ' + path + '; ' + shellCmd, timeout]]
    run_ssh_cmds(node, cmds)

'''
    Given a list of multiprocessing:Process objects,
    wait until all the Process objects have completed.
'''
def process_wait(procs, timeout=100):

    numProcsStart = len(procs)

    # wait for all the processes to complete
    while procs and timeout:
        print("\t\t:: Check processes... ({} processes remain)".format(len(procs)), file=sys.stderr)
        for i, proc in enumerate(procs):
            if proc.is_alive():
                time.sleep(10)
                timeout -= 1
            else:
                exitcode = proc.exitcode
                if exitcode:
                    print("Encountered a non-0 exit code, {} in a forked child process.".format(exitcode), file=sys.stderr)
                    sys.exit(exitcode)
                    #raise Exception("Non-0 exit code ")
                del procs[i]
                break

    if timeout:
        print("All processes completed with 0 exit code", file=sys.stderr)
    else:
        raise Exception("Timed out waiting for processes to complete! {}/{} processes remain!".format(len(procs), numProcsStart))

'''
    User specifies memory size in GB.
    Return value used by SDK
    Right now is bytes

    :param sizeGB: (int) size in GB to make memory

    :returns (int) value in bytes
'''
def convert_mem_size(sizeGB):

    converted = sizeGB * math.pow(2, 30)
    return int(converted)

'''
    display a summary of work done
    (putting in own function right now so can deal with where to direct output... in here only
    once logging set up ill change
'''
def display_summary(vmids, ram, cores, ovirt_cluster, installpath=None, clustersummary=None):

    ips, vm_summary = vm_summary_str(vmids, ram, cores, ovirt_cluster, installpath=installpath)

    print("SUMMARY START", file=sys.stderr) # will get for thsi
    print(vm_summary, file=sys.stderr)
    if clustersummary:
        print(clustersummary, file=sys.stderr)
    # print each of the vm ids to stdout
    print("\n", file=sys.stderr)
    for ip in ips:
        print(ip)
    print("\nSUMMARY END", file=sys.stderr)

'''
    Generate a useful String for the user with details abotu a cluster
'''
def cluster_summary_str(node0ip, clustername, uname, pword, nodeips):

    summary_str = "\n\n~~~~~~~~~~ A NEW CLUSTER EXISTS ~~~~~~~~~~"
    summary_str = summary_str + "\n\nCluster name: {}".format(clustername)
    summary_str = summary_str + "\nAccess URL:\n\thttps://{}:8443".format(node0ip)
    summary_str = summary_str + "\n\n\t\tusername: {}".format(uname)
    summary_str = summary_str + "\n\t\tpassword: {}\n".format(pword)
    for i, ip in enumerate(nodeips):
        # get the name of the VM
        vmname = get_vm_name(get_vm_id(ip))
        summary_str = summary_str + "\n\t\tNode{}: {} ({})".format(i, ip, vmname)
    summary_str = summary_str + "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    return summary_str

'''
    Generate a useful String for user with summary of VMs
'''
def vm_summary_str(vmids, ram, cores, ovirt_cluster, installpath=None):

    # get the data out here in case print statements get added to those methods...
    vm_data = []
    ips = []

    for vmid in vmids:
        ip = get_vm_ip(vmid)
        ips.append(ip)
        vm_data.append([ip, get_vm_name(vmid)])

    summary_str = "\n\n------ Your Ovirt VMs are ready!!! --------"
    summary_str = summary_str + "\n|\n|  VMs have the following specs:"
    summary_str = summary_str + "\n|\tRAM (GB)     : {}".format(ram)
    summary_str = summary_str + "\n|\t#  Cores     : {}".format(cores)
    #summary_str = summary_str + "\n|\tOvirt cluster: {}".format(ovirt_cluster) # it might have gone to another cluster. need to check through sdk
    if installpath:
        summary_str = summary_str + "\n|\tXcalar Bld   : {}".format(installpath)
        summary_str = summary_str + "\n|\tXcalar login : xdpadmin / Welcome1"
    summary_str = summary_str + "\n=====================THE VMS=========================\n|"
    for i, vmdata in enumerate(vm_data):
        summary_str = summary_str + "\n|\n| VM #{}:".format(i)
        summary_str = summary_str + "\n|\tIP: {}".format(vmdata[0])
        summary_str = summary_str + "\n|\tName (in Ovirt): {}".format(vmdata[1])
        summary_str = summary_str + "\n|\tssh creds: jenkins/{}".format(JENKINS_USER_PASS)
        if installpath:
            summary_str = summary_str + "\n|\tURL: https://{}:8443".format(vmdata[0])
    summary_str = summary_str + "\n|\n======================================================"
    summary_str = summary_str + "\n--------------------------------------------------------\n"

    return ips, summary_str

def validateparams(args):

    licfilepath = args.licfile
    pubsfilepath = args.pubsfile
    installerpath = args.installer

    if args.vms:

        if args.vms > MAX_VMS_ALLOWED:
            err = "Max num of VMs allowed to create: {}.  Pleasae re-run with --vms less than this".format(MAX_VMS_ALLOWED)
            print(err, file=sys.stderr)
            sys.exit(1)

        '''
            if they're trying to create a cluster,
            make sure they have access to /netstore because
            This script will try to access that mnt point locally
        '''
        if args.createcluster:
            if args.vms == 1:
                err = "\nError!  You specified to create a cluster, but only want to provision one VM!  Is this what you wanted?\n"
                print(err, file=sys.stderr)
                sys.exit(1)
            if not os.path.exists('/netstore'):
                err = '''You are trying to create a cluster, but do not have netstore mounted locally
                        at /netstore.  Please make netstore accessible on machine you're calling this script from'''
                print(err, file=sys.stderr)
                sys.exit(1)

        if args.noxcalar:
            if args.installer:
                print("\nError: You have specified not to install xcalar with the --noxcalar option,\n"
                    "but also provided an installation path with the --installer option. "
                    "\n(Is this what you intended?)", file=sys.stderr)
                sys.exit(1)
        else:
            '''
                license files for xcalar.
                If they plan on installing xcalar on the new VMs,
                and did not supply lic of pub file options,
                look in their cwd
            '''
            print("\nMake sure license keys are present....", file=sys.stderr)

            if not licfilepath:
                licfilepath = LICFILENAME
                print("\tYou did not supply --licfile option... will look in cwd for Xcalar license file...", file=sys.stderr)
            if not os.path.exists(licfilepath):
                err = '''Error: File {} does not exist!
                    (Re-run with --licfile=<path to your licence file>,
                    or, copy the file in to the directory you are running
                    this script from '''.format(LICFILEPATH)
                print(err, file=sys.stderr)
                sys.exit(1)

            if not pubsfilepath:
                pubsfilepath = PUBSFILENAME
                print("\tYou did not supply --pubsfile option... will look in cwd for pubs file...", file=sys.stderr)
            if not os.path.exists(pubsfilepath):
                err = '''\nError: File {} does not exist!
                    (Re-run with --pubsfile=<path to your licence file>,
                    or, copy the file in to the directory you are running
                    this script from'''.format(PUBSFILEPATH)
                print(err, file=sys.stderr)
                sys.exit(1)

            if not installerpath:
                installerpath = 'builds/Release/xcalar-latest-installer-prod' # path on Netstore
                print("\tYou did not supply --installer option ... will use latest RC installer", file=sys.stderr)
            if not os.path.exists('/netstore/' + installerpath):
                err = '''\n\nError: Could not find RPM installer at path {} on netstore
                        (Did you specify the prod dir, instead of the installer itself?)'''.format(installerpath)
                print(err, file=sys.stderr)
                sys.exit(1)
    else:

        '''
            if not trying to create vms,
            make sure at least runing to remove VMs then, else nothing to do
        '''
        if not args.delete:
            err = "Please re-run this script with arg --vms=<number of vms you want>"
            print(err, file=sys.stderr)
            sys.exit(1)

    return int(args.ram), int(args.cores), args.ovirtnode, licfilepath, pubsfilepath, installerpath

if __name__ == "__main__":

    '''
        Parse and validation cmd arguments
    '''

    parser = argparse.ArgumentParser()
    parser.add_argument("--vms", type=int, default=0, help="Number of VMs you'd like to create")
    parser.add_argument("--createcluster", action='store_true', help="Create a cluster of the new VMs.")
    parser.add_argument("--installer", type=str, #default='builds/Release/xcalar-latest-installer-prod',
        help="Path (rel to NETSTORE root) to the Xcalar installer you want to install on your VMs.  If not supplied, will use latest RC build.")
    parser.add_argument("--cores", type=int, default=4, help="Number of cores per VM.")
    parser.add_argument("-f", "--force", action="store_true", default=False, help="Force certain operations such as provisioning, delete, when script would fail normally")
    parser.add_argument("--ram", type=int, default=8, help="RAM on VM(s) (in GB)")
    parser.add_argument("--noxcalar", action="store_true", default=False, help="Don't install Xcalar on provisioned VMs")
    parser.add_argument("--ovirtnode", type=str, default='node3-cluster', help="Which node to create the VM(s) on.  Defaults to node4-cluster")
    parser.add_argument("--tryotherclusters", action="store_true", default=False, help="If supplied, then if unable to create the VM on the given Ovirt cluster, will try other clusters on Ovirt before giving up")
    parser.add_argument("--licfile", type=str, help="Path to a XcalarLic.key file on your local machine (If not supplied, will look for it in cwd)")
    parser.add_argument("--pubsfile", type=str, help="Path to an EcdsaPub.key file on your local machine (If not supplied, will look for it in cwd)")
    parser.add_argument("--delete", type=str, help="Single VM or comma separated String of VMs you want to remove from Ovirt (could be, IP, VM name, etc).")
    parser.add_argument("--user", type=str, help="Your SSO username (no '@xcalar.com')")

    args = parser.parse_args()

    ram, cores, ovirtnode, licfilepath, pubsfilepath, installerpath = validateparams(args)
    FORCE = args.force

    #open connection to Ovirt server
    CONN = open_connection(user=args.user)

    '''
        remove vms first if requested, to free up resources
    '''
    if args.delete:
        remove_vms(args.delete.split(','))

    ''''
        main driver
    '''

    #  spin up number of vms requested
    vmids = []
    if args.vms:
        basename, vmids = provision_vms(int(args.vms), ovirtnode, convert_mem_size(ram), cores, user=args.user, tryotherclusters=args.tryotherclusters) # user gives RAM in GB but provision VMs needs Bytes

        if not args.noxcalar:
            # if you supply a value to 'createcluster' arg of initialize_xcalar,
            # then once xcalar install compled on all nodes will form the vms in
            # to a cluster by that name
            clustername = None
            if args.createcluster:
                clustername = basename
            initialize_xcalar(vmids, licfilepath, pubsfilepath, installerpath, createcluster=clustername)

        '''
            display a useful summary to user which has IP, VM names, etc.
        '''
        # using a CLUSTER_SUMMARY global variable instead of determining summary of cluster here
        # because create_cluster function (which sets that global) knows which node is the node0, node1, etc.
        # out here guess would be based on order of elements in the list sending to initialize_xcalar and that could change...
        # so @TODO, log in to one of the cluster nodes,
        # verify cluster, get node0, etc. directly fromr the cluster node... then can determine here..
        # at that point do away with the global CLUSTER_SUMMARY String
        display_summary(vmids, ram, cores, ovirtnode, installpath=installerpath, clustersummary=CLUSTER_SUMMARY)

    # close connection
    close_connection(CONN)

