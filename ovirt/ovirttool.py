#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""

Tool to spin up VMs on Ovirt and create Xcalar clusters

@examples

    create single VM called myvm with all the defaults and Xcalar installed (latest BuildTrunk prod build is default)

        python ovirttool.py --count=1 --vmbasename=myvm

    create two VMs (myvm-vm0 and myvm-vm1) with all defaults and no Xcalar installed

        python overttool.py --count=2 --vmbasename=myvm --noinstaller

    create two VMs (myvm-vm0 and myvm-vm1) with all the defaults and Xcalar installed; form in to a cluster

        python ovirttool.py --count=2 --vmbasename=myvm

    create two VMs (abc-vm0 and abc-vm1) with default configurations and Xcalar installed; dont form in to cluster

        python ovirttool.py --count=2 --nocluster --vmbasename=abc

    Create two node cluster with 32 GB ram and 8 cores, using a custom installer.  The VMs are called myclus-vm0 and myclus-vm1 and cluster called myclus

        python ovirttool.py --count=2 --vmbasename=myclus --ram=32 --cores=8 --installer=http://netstore/builds/byJob/BuildTrunk/lastSuccessful/debug/xcalar-1.3.1-1657-installer

"""

import ovirtsdk4 as sdk
import ovirtsdk4.types as types

import argparse
import getpass
import logging
import math
import multiprocessing
import os
from os.path import expanduser
import paramiko
import re
import requests
import shutil
import socket
import subprocess
import sys
import time
import urllib

logging.basicConfig(level=logging.DEBUG, filename='example.log')

MAX_VMS_ALLOWED=1024

NETSTORE_IP='10.10.1.107'
XUID = '1001' # xcalar group uid. hacky fix later
JENKINS_USER_PASS = "jenkins" # password to set for user 'jenkins' on provisioned VMs
LOGIN_UNAME = "xdpadmin"
LOGIN_PWORD = "Welcome1"
LICENSE_KEY = "H4sIAAAAAAAAA22OyXaCMABF93yF+1YLSKssWDAKiBRR1LrpCSTWVEhCCIN/Xzu46/JN575AIA4EpsRQJ7IU4QKRBsEtNQ4FKAF/HAWkkBJOYVsID1S4vP4lIwcIMEpKIE6UV/fK/+EO8eYboUy0G+RuG1EQZ4f3w4smuQPDvzduQ2Sosjofm4yPp7IUU4hs2hJhKLL6LGUN4ncpS6/kZ3k19oATKYR54RKQlwgagrdIavAHAaLlyNALsVwhk9nHM7apnvbrc73q9BCh2duxPZbJ4GtPpjy4U6/uHKrBU6U4ijazYekVRDBrEyvJcpUTD+2UB9RfTNtleb0OPbjFl21PqgDvFStyQ2HFrtr7rb/2mZDpYtqmGasTPez0xYAzkeaxmaXFJtj0XiTPmW/lnd5r7NO2ehg4zuULQvloNpIBAAA="

TMPDIR_LOCAL='/tmp/ovirt_tool' # tmp dir to create on local machine running python script, to hold pem cert for connecting to Ovirt
TMPDIR_VM='/tmp/ovirt_tool' # tmp dir to create on VMs to hold helper shell scripts, lic files (dont put timestamp because forking processes during install processing)
CLUSTER_DIR_VM='/mnt/xcalar' # if creating cluster of the VMs and need to mount netstore, will be local dir to create on VMs, to mount shared storage space to.

OVIRT_KEYFILE_SRC = 'id_ovirt' # this a file to supply during ssh.  need to chmod it for scp but dont want it to show up in users git status, so this its loca nd will move it to chmod
home = os.path.expanduser('~') # '~' gives issues with paramiko; expand to home dir, this swill work cross-platform
OVIRT_KEYFILE_DEST = home + '/.ssh/id_ovirt'

CONN=None
LICFILENAME='XcalarLic.key'
# helper scripts - they should be located in dir this python script is at
INSTALLER_SH_SCRIPT = 'e2einstaller.sh'
TEMPLATE_HELPER_SH_SCRIPT = 'templatehelper.sh'
ADMIN_HELPER_SH_SCRIPT = 'setupadmin.sh'

FORCE = False # a force option will allow certain operations when script would fail otherwise (use arg)

# Ovirt GUI search bar has search refining keywords
# if you try to name a VM starting with one of these, vms_service.list api will
# fail if that name is the identifier.  add these here so can fail on param validation
# (else the script will fail after provisioning and it is not obvious at all why its failing)
PROTECTED_KEYWORDS = ['cluster', 'host', 'fdqn', 'name']

class NoIpException(Exception):
    pass

def info(string):
    print(string, file=sys.stderr)

'''
    OVIRT SDK FUNCTIONS
'''

'''
    Start a VM by given ID,
    and wait until it is up.
    if requested, wait until IP is generated
    and showing up in Ovirt

    :param vmid: unique id of VM (ovirtsdk4:types:Vm.id attr)
    :param waitForIP: (optional boolean, default to false)
        - if True: wait for IP to be assigned and displaying before returning
            (throws TimeoutError if not up after certain time)
        - if False, return immediately after vm status is UP; don't
            wait for IP assignment

    :returns:
        if waitForIp - the String of the IP that got assigned to the new VM

    :throws Exception if any stage not successfull
'''
def bring_up_vm(vmid, waitForIP=None):

    vm_service = get_vm_service(vmid)
    name = get_vm_name(vmid)

    if is_vm_up(vmid):
        # the api will throw exception if you try to start and it's in up state already
        info("Vm {} is already up!  I will not start".format(name))
    else:
        info("\nStart service on {}".format(name))
        timeout=60
        while timeout:
            try:
                # start the vm
                vm_service.start()
                info("started service!")
                break
            except Exception as e:
                if 'VM is locked' in str(e):
                    time.sleep(10)
                    timeout-=1
                    info("vm is still locked; can't start service yet... try again...")
                else:
                    # another exception don't know about - re-raise.  if the resource excpetion from Ovirt
                    # want to raise that will handle it higher up in the provision_vm function
                    if 'memory' in str(e):
                        info("Throwing memory exception: {}".format(str(e)))
                    raise e
        if not timeout:
            raise TimeoutError("Was never able to start service on {}!".format(name))

        info("\nWait for {} to come up".format(name))
        timeout=120
        while timeout:
            if is_vm_up(vmid):
                info("\t{} is up!".format(name))
                break
            else:
                time.sleep(5)
                timeout-=1
        if not timeout:
            raise TimeoutError("Started service on {}, but VM never came up!".format(name))

    if waitForIP:
        info("\nWait until IP assigned and displaying for {}".format(name))
        timeout = 30
        while timeout:
            try:
                info("try to get vm ip")
                ip = get_vm_ip(vmid)
                info("\tIP {} assigned to {}!".format(ip, name))
                return ip
                break
            except:
                # not available yet
                info("still no ip")
                timeout -= 1
                time.sleep(6)
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
def create_vm(name, cluster, template, ram, cores, feynmanIssueRetries=4, iptries=5):

    info("\nCreate a new VM called: {}\n\tOvirt cluster: {}\n\tTemplate VM  : {}\n\tRAM (bytes)  : {}\n\t# cores      : {}".format(name, cluster, template, ram, cores))

    # Get the reference to the "vms" service:
    vms_service = CONN.system_service().vms_service()
    info("got vms service")

    # create the VM Object and add to vms service
    # need a types:Cpu object to define cores
    vm_cpu_top = types.CpuTopology(cores=cores, sockets=1)
    vm_cpu = types.Cpu(topology=vm_cpu_top)

    '''
        Issue: Since Feynman went down, the IPs of the down VMs
        are being re-assigned, but in Ovirt, the IPs remain attached
        to the downed Feynman machines, in addition to new VM they get
        provisioned to.
        This happens about 1 in 10 times a new VM is created.
        This causes the tool to fail, because the tool is expecintg only
            one VM in Ovirt to be associated with a given IP, so that it
            has a way to know (given an IP to do work on),
            which VM that IP is referring to.
        So once a VM is created, if there is more than one hit for its IP,
		delete the VM and try creating it again, hoping to get a new IP
    '''
    feynmanTries = feynmanIssueRetries
    while feynmanTries:
        feynmanTries -= 1

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
        info("VM added...")

        # get id of the newly added vm (can't get from obj you just created.  need to get from vms service)
        vmid = get_vm_id(name)
        info("\tid assigned: {}...".format(vmid))
        # corner case: if they named it starting with a search keyword Ovirt uses,
        # the VM will be added, but get_vm_id will return no results.
        # trying to handle these in param validation but there could be more keywords
        if not vmid:
            raise RuntimeError("VM {} was successfully created, "
                "but not finding the VM through Ovirt sdk\n"
                "(Is there any chance the name {} starts with one of Ovirt's search keywords?"
                " if so, please modify this tool and add to PROTECTED_KEYWORDS so vms of this name"
                " will not be allowed)\n"
                "If not - Open ovirt, and try to type this name in the main search bar."
                " are there any results?  If so, this indicates something is wrong with the API".format(name, name))

        # start vm and bring up until IP is displaying in Ovirt
        info("Bring up {}...".format(vmid))
        # sometimes IP not coming up first time around.  restart and ty again
        triesleft = iptries
        assignedIp = None
        while triesleft:
            try:
                time.sleep(5)
                assignedIp = bring_up_vm(vmid, waitForIP=True)
                break
            except NoIpException:
                info("WARNING: Timed out waiting for IP on new VM... will restart and try again...")
                triesleft -= 1
                stop_vm(vmid)

        if not assignedIp:
            raise RuntimeError("\n\nERROR: Never got Ip for {}/[id:{}],\n"
                " even after {} restarts (dhcp issue?)\n".format(name, vmid, iptries))

        # IP came up, but make sure it is actually unique to this new VM for Ovirt (feynman issue)
        matchingVMs = get_matching_vms(assignedIp)
        if len(matchingVMs) > 1:
            info("\n\n\t --- FEYNMAN ISSUE HIT {} ---:\n\t"
                "The IP that got assigned to your new VM "
                " was re-assigned from an existing VM, but Ovirt associates "
                " of these VMs with that IP!"
                "\n(This is probably due to the Feynman outage)\n"
                "Going to delete this new VM and re-create it, to try "
                " and get a unique IP".format(name))
            remove_vm(name, releaseIP=False) # set releaseIP as False -
                # since it's of no use as the issue is that the IP is being re-assigned!
            continue
        else:
            break

    if feynmanTries:
        info("\nSuccessfully created VM {}, on {}!!".format(name, cluster))
        #\n\tIP: {}\n\tCluster: {}\n\tTemplate {}".format(myvmname, new_ip, cluster, template))
        return vmid
    else:
        raise RuntimeError("VM was being provisioned, but kept getting re-assigned "
            " IPs already registered with Ovirt.  Tried {} times before giving up!"
            .format(feynmanIssueRetries))

def setup_hostname(ip, name):

    info("Set hostname of VM {} to {}".format(ip, name))
    fqdn = "{}.int.xcalar.com".format(name)
    run_ssh_cmd(ip, '/bin/hostnamectl set-hostname {}; echo "{} {} {}" >> /etc/hosts; service rsyslog restart'.format(name, ip, fqdn, name))
    run_ssh_cmd(ip, 'systemctl restart network')
    run_ssh_cmd(ip, 'systemctl restart autofs')

def reboot_node(ip):

    try:
        run_ssh_cmd(ip, 'reboot -h')
    except Exception as e:
        info("expect to hit exception after the reboot")

def puppet_setup(ip, puppet_role, puppet_cluster):

    info("Setup puppt to run on {} as role {}".format(ip, puppet_role))
    cmds = [
        ['echo "role={}" > /etc/facter/facts.d/role.txt'.format(puppet_role)],
        ['echo "cluster={}" > /etc/facter/facts.d/cluster.txt'.format(puppet_cluster)],
        ['/opt/puppetlabs/bin/puppet agent -t -v', 2700, [0, 2]],
    ]
    run_ssh_cmds(ip, cmds)

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
        info("{} bytes memory available on cluster {}".format(mem_available_this_cluster, cluster))

        # see how many VMs you could make with that
        consumes = math.floor(mem_available_this_cluster/ram)
        info("{} vms could be consumed by cluster {}".format(consumes, cluster))

        # if it couldn't create any VMs at all, don't include in list returned
        if consumes:
            info("Cluster {} could consume {} vms... add to useful clusters".format(cluster, consumes))
            useful_clusters.append(cluster)

        # update how many VMs left in request.
        # if that takes care of rest of VMs, guess is that enough available memory!
        # return list of useful clusters!
        vms_remaining = vms_remaining - consumes
        info("{} would vms remain in request...".format(vms_remaining))
        if vms_remaining <= 0:
            # add rest of the clusters in (no harm for more resources)
            info("Guess is clusters should be able to handle the VM request load (others could be using clusters though)")
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
            info("Host {} is not UP.  Do not figure in to available memory estimates...".format(host.name))
            continue

        if host.cluster:
            # cluster attr is a link.  follow link to retrieve data about the cluster
            cluster = CONN.follow_link(host.cluster)
            # try to get the name
            if cluster.name and cluster.name == name:
                info("Host {} is part of requested cluster, {}".format(host.name, cluster.name))
                # add this hosts available memory to cnt
                if host.max_scheduling_memory:
                    info("Host {}'s max scheduling memory (in bytes): {}".format(host.name, str(host.max_scheduling_memory)))
                    mem_found = mem_found + host.max_scheduling_memory

    info("Available memory found on cluster {}: {} bytes".format(name, mem_found))
    return int(mem_found)

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

    info("\nTry to find VMs matching identifier {}".format(identifier))

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

    info("\nTry to find id of VM using identifier: {}".format(identifier))
    matches = get_matching_vms(identifier)
    if matches:
        if len(matches) > 1:
            raise ValueError("\n\nERROR: More than one VM matched on identifier {}!  "
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
    info("\nGet IP of VM {}".format(name))

    vm_service = get_vm_service(vmid)
    info("got vm service " + str(vm_service))

    devices = vm_service.reported_devices_service().list()
    for device in devices:
        info("\tFound device: {}".format(device.name))
        if device.name == 'eth0':
            info("is eth0")
            ips = device.ips
            for ip in ips:
                info("\tip " + ip.address)
                # it will return mac address and ip address dont return mac address
                if ip_address(ip.address):
                    return ip.address
                else:
                    info("\t(IP {} is probably a mac address; dont return this one".format(ip.address))

    # never found!
    #return None
    raise NoIpException("Never found IP for vm: {}".format(name))

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
        raise RuntimeError("\n\nERROR: Attempting to get vm name; "
            " couldn't retrieve vms service for vm of id: {}\n".format(vmid))
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
        info("Could not locate a vm service for vm id {}".format(vmid))
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
        info("VM status: {}".format(vm.status))
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

    info("\nTry to Remove VM {} from Ovirt\n".format(identifier))
    # try to get the vm to remove...
    vmid = get_vm_id(identifier)
    if not vmid:
        info("No VM found to remove, using identifier : {}".format(identifier))
        raise RuntimeError("\n\nERROR: Could not remove vm of identifier: {}; "
            " VM does not return from search!\n".format(identifier))
    name = get_vm_name(vmid)

    vm_service = get_vm_service(vmid)

    if releaseIP:
        '''
            Want to release IP before removal.
            Need VM to be up to get IP.
            If VM down bring up so can get IP.
            Then SSH and release the IP
        '''
        info("Attempt to release ip before removing {}".format(name))

        if not is_vm_up(vmid):
            info("\nBring up {} so can get IP...".format(name))
            bring_up_vm(vmid, waitForIP=True)

        # if vm up, wait until ip displaying in case
        # this is a vm that was just created and we tried to
        # remove right away
        timeout = 10
        while timeout:
            try:
                ip = get_vm_ip(vmid)
                # dev check -it should be throwing exception if can't find
                # if switched to returning None need to update logic
                if ip is None:
                    raise Exception("\n\nLOGIC ERROR:: get_vm_ip was raising exception when can't find ip"
                        " now returning None.  Please sync code")
                break
            except NoIpException:
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
            info("\nFound IP of VM... Release IP {}".format(vm_ip))
            cmds = [['dhclient -v -r']] # assuming Centos7... @TODO for other cases?
            run_ssh_cmds(vm_ip, cmds)
        else:
            info("\nWARNING: I could still never get an IP for {}, "
                " even though it shows as up,"
                " will just shut down and remove VM without IP release".format(name))
            #raise Exception("Never found IP for {}, even though it shows as up".format(name))

    # must power down before removal
    if is_vm_up(vmid):

        info("\nStop VM {}".format(name))
        timeout=60
        while timeout:
            try:
                vm_service.stop()
                break
            except Exception as e:
                timeout-=1
                time.sleep(5)
                info("still getting an exception...." + str(e))
        if not timeout:
            raise TimeoutError("Couldn't stop VM {}".format(name))

        timeout=60
        info("\nWait for service to come down")
        while timeout:
            vm = vm_service.get()
            if vm.status == types.VmStatus.DOWN:
                info("vm status: down!")
                break
            else:
                timeout -= 1
                time.sleep(5)
        if not timeout:
            raise TimeoutError("Stopped VM {}, but service never came donw".format(name))

    info("\nRemove VM {} from Ovirt".format(name))
    timeout = 5
    while timeout:
        try:
            vm_service.remove()
            break
        except Exception as e:
            time.sleep(5)
            if 'is running' in str(e):
                info("vm still running... try again...")
            else:
                raise SystemExit("unexepcted error when trying to remve vm, {}".format(str(e)))
    if not timeout:
        raise TimeoutError("Stopped VM {} and service came down, but could not remove from service".format(name))

    info("\nWait for VM to be gone from vms service...")
    timeout = 20
    while timeout:
        try:
            match = get_vm_id(name)
            info("Vm still exist...")
            # dev check: make sure that function didn't change from throwing exception
            # to returning None
            if not match:
                raise Exception("\n\nLOGIC ERROR IN CODE: get_vm_id was throwing Exception on not being able to find"
                    " vm of given identifier, now it's returning None.  Please sync code\n")
            time.sleep(5)
            timeout -= 1
        except:
            info("VM {} no longer exists to vms".format(name))
            break
    if not timeout:
        raise TimeoutError("Stopped VM {} and service came down and removed from service, "
            " but still getting a matching id for this vm!".format(name))

    info("\n\nSuccessfully removed VM: {}".format(name))

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

    info("Remove VMs {} in parallel".format(vms))

    procs = []
    badvmidentifiers = []
    sleepBetween = 5
    sleepOffset = 0
    for vm in vms:
        if get_matching_vms(vm):
            proc = multiprocessing.Process(target=remove_vm, args=(vm,), kwargs={'releaseIP':releaseIP})
            proc.start()
            procs.append(proc)
            time.sleep(sleepBetween)
            sleepOffset += sleepBetween
        else:
            badvmidentifiers.append(vm)

    # wait for the processes
    process_wait(procs, timeout=500+sleepOffset)

    if badvmidentifiers:
        valid_vms = get_all_vms()
        raise ValueError("\n\nYou supplied some invalid VMs to remove.\nValid VMs:\n\n\t{}" \
            "\n\nCould not find matches in Ovirt for following VMs: {}." \
            "  See above list for valid VMs\n".format("\n\t".join(valid_vms), ",".join(badvmidentifiers)))

def reboot_nodes(vmids):

    info("Reboot nodes in parallel")

    procs = []
    for vmid in vmids:
        ip = get_vm_ip(vmid)
        proc = multiprocessing.Process(target=reboot_node, args=(ip,))
        proc.start()
        procs.append(proc)

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
        info("VM is already down!  No need to stop...")
        return True

    # Call the "stop" method of the service to stop it:
    vm_service.stop()

    # Wait till the virtual machine is down:
    while timeout:
        time.sleep(5)
        vm = vm_service.get()
        if vm.status == types.VmStatus.DOWN:
            info("VM is now down....")
            return True
        else:
            timeout -= 1

    if not timeout:
        raise TimeoutError("\n\nERROR: Timed out waiting for VM to come down\n")

'''
    Open connection to Ovirt engine.
    (sdk advises to free up this resource when possible)

    :returns: ovirtsdk4:Connection object
'''
def open_connection(user=None):

    info("\nOpen connection to Ovirt engine...")

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
            info("Error:", err)

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

    info("close connection to ovirt engine...")
    conn.close()

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
    #info(response.text)
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
def provision_vm(name, puppet_role, puppet_cluster, ram, cores, availableClusters):

    info("\nTry to provision VM {} on one of the following clusters: {}".format(name, availableClusters))

    for orderedcluster in availableClusters:
        template = get_template(orderedcluster)
        try:
            vmid = create_vm(name, orderedcluster, template, ram, cores)

            if not vmid:
                raise RuntimeError("\n\nERROR: Ovirt seems to have successfully created VM {}, but no id generated\n".format(name))

            # set jenkins password before returning
            # do here instead of during installation in case they don't want to install xcalar
            ip = get_vm_ip(vmid)
            info("Change password for user 'jenkins' on {} ({})".format(name, ip))
            run_ssh_cmd(ip, 'echo "jenkins:{}" | chpasswd'.format(JENKINS_USER_PASS))

            # set the hostname now (in case they don't want to install Xcalar)
            setup_hostname(ip, name)
            # setup puppet only after hostname is set
            puppet_setup(ip, puppet_role, puppet_cluster)

            return True
        #except ResourceException as err:
        except Exception as e:
            info("Exception hit when provisioning VM {}!".format(name))
            if 'available memory is too low' in str(e):
                info("Hit memory error!! :"
                    " Not enough memory on {} to create requested VM"
                    "\nTry to delete it and try on next cluster (if any)...".format(orderedcluster))
                remove_vm(name, releaseIP=False) # set releaseIP as False - else, it's going to try and bring the VM up again to get the IP! and will fail for same reason
            else:
                info("VM provisioning failed for a reason other than memory too low")
                raise e
                #raise Exception("Failed for another reason!: {}".format(str(e)))

    # hit this problem in all of them
    errMsg = "\n\nERROR: There are not enough resources available " \
        " to provision the next VM of {} bytes RAM, {} cores\n" \
        " Tried on clusters: {}".format(ram, cores, availableClusters)
    info(errMsg)
    sys.exit(1) # do a sys exit instead of raising exception because then this process will terminate
    # elses if its being called as a subprocess you're going to have to wait for it to time out
    #raise Exception(errMsg)

'''
    provisions n vms in parallel.
    waits for all vms to come up with ips displaying
    Return a list of names of vms created in Ovirt

    :param n: (int) number of VMs to create
    :param basename: name to base vm names on
    :param ovirtcluster: which cluster in Ovirt to create VMs from
    :param ram: (int) memory (in GB) on each VM
    :param cores: (int) num cores on each VM
    :param user: (optional String) name of user.  if given will include in the new VM names

    :returns: list of unique vm ids for each VM created
        (this is distinct from name; its id attr of Type:Vm Object)

'''
def provision_vms(n, basename, ovirtcluster, puppet_role, puppet_cluster, ram, cores, user=None, tryotherclusters=True):

    if n == 0:
        return None

    if not ram or not cores:
        raise ValueError("\n\nERROR: No value for ram or cores args to provision_vms\n"
            " (perhaps default values changed for the --ram or --cores options?)\n")

    # check if any vms with the basename, if so they need to specify something different
    '''
        false negative cornercase!!!

        If the basename you check is one of Ovirts search refining keywords
        (i.e., a string you can type in the GUI's main search field to refine a search,
        such as the string 'name')
        then match will return NO results, even if there ARE vms by that name!

        (This is because, this call essentially has the same effect as typing the arg passed in,
        in to the GUI's main search field; it returns a types.Vm object for each 'row' you'd see
        if you typed that value in the search field.
        therefore, if the basename you're passing, begins wth one of Ovirt's search refining keywords,
        the search will NOT return results because it's interpreting that value, as a search keyword!)
    '''
    matches = get_matching_vms(basename)
    info("matches: ")
    info(matches)
    if matches:
        matches = [x.name for x in matches]
        raise ValueError("\n\nERROR: The value you specified as the basename for requested VM(s), {},"
            " is already in use by Ovirt, for the following VMs:\n\t{}\n"
            "Please re-run and specify a different basename to --vmbasename option\n".format(basename, matches))

    info("\nProvision {} vms on ovirt node {}\n".format(n, ovirtcluster))

    '''
        get list of cluster we can try to provision the VMs on.
        (if tryotherclusters is True, then can try on other clusters
        other than one specified by ovirtcluster param, in case something
        goes wrong on that cluster)
    '''
    availableClusters = [ovirtcluster]
    if tryotherclusters:
        availableClusters = get_cluster_priority(prioritize=ovirtcluster)
    info("\nClusters available to provision the vms on: {}".format(availableClusters))

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
        info("\nCheck first if enough memory available...")
        fullClusList = availableClusters # if fail want to print out the original list of clusters in err message
        availableClusters = enough_memory(n, ram, availableClusters)
        info("\nClusters determined we can use: {}".format(str(availableClusters)))
        if not availableClusters:
            errmsg = "\n\nError: There is not enough memory on cluster(s) {}, " \
                "to provision the requested VMs\n" \
                "Try to free up memory on the cluster(s).\n".format(fullClusList)
            if not tryotherclusters:
                errmsg = errmsg + "You can also run this tool with --tryotherclusters option, " \
                    " to make other clusters available to you during provisioning\n"
            errmsg = errmsg + "\nTo ignore this error and try to provision anyway, re-run with --force option\n"
            raise RuntimeError(errmsg)

    procs = []
    vmnames = []
    sleepBetween = 20
    for i in range(n):
        nextvmname = basename
        if n > 1:
            nextvmname = nextvmname + "-vm{}".format(str(i))
        vmnames.append(nextvmname)
        info("\nFork new process to create a new VM by name {}".format(nextvmname))
        proc = multiprocessing.Process(target=provision_vm, args=(nextvmname, puppet_role, puppet_cluster, ram, cores, availableClusters))
        #proc = multiprocessing.Process(target=create_vm, args=(newvm, ovirtcluster, template, ram, cores)) # 'cluster' here refers to cluster the VM is on in Ovirt
        # it will fail if you try to create VMs at exact same time so sleep
        proc.start()
        procs.append(proc)
        time.sleep(sleepBetween)

    # TODO: Deal with 'image locked' status because of network issue on node

    # wait for the processes
    process_wait(procs, timeout=4000+sleepBetween*n, valid_exit_codes=[0, 2]) # 0 and 2 both valid exit code for puppet which will get set up

    # get the list of the unique vm ids
    # a good check to make sure these VMs actually existing by these names now
    ids = []
    for vm in vmnames:
        ids.append(get_vm_id(vm))
    #return vm_names
    return ids

'''
    Check if Xcalar service running on a node

    :param node: (String) ip of node to check status of Xcalar service on

    :returns: (boolean) True if Xcalar service running;
        False if not runing
'''
def is_xcalar_running(node):
    raise NotImplementedError("Have not yet implemented is_xcalar_running")

'''
    Bring up Xcalar service on node

    :param node: (String) ip of node to start Xcalar service on
'''
def start_xcalar(node):

    info("\nStart Xcalar service on node {}\n".format(node))
    cmds = [['service xcalar start', 600]]
    run_ssh_cmds(node, cmds)

'''
    Bring down Xcalar service on node

    :paran node: (String) ip of node to stop xcalar service on
'''
def stop_xcalar(node):

    info("\nStop Xcalar service on node {}\n".format(node))
    cmds = [['service xcalar stop', 120]]
    run_ssh_cmds(node, cmds)

'''
    Bring up xcalar service on a node and setup admin account

    :param node: (String) ip of node to setup admin account on
'''
def setup_admin_account(node):

    info("\nSetup admin account on {}\n".format(node))

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

    :param ip: (String)
        IP of VM to install Xcalar on
    :param licfilepath: (String)
        path on local machine runnign this script, of Xcalar license file
    :param installer: (String)
        URL for an RPM installer on netstore (valid URL user should be able to curl)

'''
def setup_xcalar(ip, licfilepath, installer):

    vmname = get_vm_name(get_vm_id(ip))

    info("\nInstall Xcalar on {} (IP: {}), using RPM at installer:\n\t{}\n".format(vmname, ip, installer))

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
        # rename lic file to std name in case they supplied a file with a diff name, because e2e script will call by st name
        [licfilepath, TMPDIR_VM + '/' + LICFILENAME]]
    for filedata in fileslist:
        scp_file(ip, filedata[0], filedata[1])

    # install using bld requested
    run_sh_script(ip, TMPDIR_VM + '/' + INSTALLER_SH_SCRIPT, args=[installer, ip], timeout=1000)

'''
    Install and setup Xcalar on a set of nodes.
    Once xcalar installation completes on all of them,
    form in to a cluster unless specified otherwise

    :param vmids: list of unique vm ids in Ovirt of VMs to install xcalar on
    :param licfilepath: (String)
        path to License file on local machine executing this script
    :param installer (String)
        curl'able URL to an RPM installer
    :param createcluster: (optional, String)
        If supplied, then once xcalar setup on the vms, will form them
        in to a cluster by name of String passed in
        If not supplied will leave nodes as individual VMs

'''
def initialize_xcalar(vmids, licfilepath, installer, createcluster=None):

    info("installer: " + str(installer))
    info("\nSetup xcalar on node set and cluster {}".format(createcluster))

    procs = []
    ips = []

    sleepBetween = 15
    for vmid in vmids:
        # get ip
        ip = get_vm_ip(vmid)
        name = get_vm_name(vmid)
        ips.append(ip)
        info("\nStart new process to setup xcalar on {}, {}".format(name, ip))
        proc = multiprocessing.Process(target=setup_xcalar, args=(ip, licfilepath, installer))
        # failing if i dont sleep in between.  think it might just be on when using the SDK, similar operations on the vms service
        procs.append(proc)
        proc.start()
        time.sleep(sleepBetween)

    # wait
    process_wait(procs, timeout=1500+sleepBetween*len(vmids))

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
        procs.append(proc)
        proc.start()
        time.sleep(sleepBetween)

    # wait for all the processes to complete successfully
    process_wait(procs, timeout=600+sleepBetween*len(ips))

'''
        FOR CLUSTER SETUP
'''

'''
    Given a list of node IPs, create a shared space for those
    nodes, and form the nodes in to a cluster.

    :param nodeips: (list of Strings)
        list of IPs of the nodes you want made in to a cluster
    :param clustername: (String)
        name you want the cluster to be
        ('cluster name' here meaning it will become dir name of shared storage space on netstore)

    @TODO: 'start' boolean param that controls if you start xcalar after cluster configured
        to pass in to child proc
'''
def create_cluster(nodeips, clustername):

    if not len(nodeips):
        raise ValueError("\n\nERROR: Empty list of node ips passed to create_cluster;"
            " No nodes  make cluster on!\n")

    '''
        Create a shared storage space for the nodes
        on netstore, using cluster name
    '''
    sharedRemoteStoragePath = 'ovirtgen/' + clustername
    create_cluster_dir(sharedRemoteStoragePath)

    # for each node, generate config file with the nodelist
    # and then bring up the xcalar service
    info("\nCreate cluster using nodes : {}".format(nodeips))
    procs = []
    sleepBetween = 15
    for ip in nodeips:
        info("\n\tFork cluster config for {}\n".format(ip))
        '''
        Note: The order of the ips in nodeips list is important!!
        Will be node 0 (root cluster node), node1, etc., in order of list
        '''
        proc = multiprocessing.Process(target=configure_cluster_node, args=(ip, nodeips, sharedRemoteStoragePath))
        procs.append(proc)
        proc.start()
        time.sleep(sleepBetween)

    # wait for all the proceses to complte
    process_wait(procs, timeout=600+sleepBetween*len(nodeips))

'''
    Create a dir on netstore by the cluster name
    Set owner to Xcalar uuid
    Create a /config dir in the shared storage space and also
    set its owner to xcalar (this is where cfg data gets written to)

    :param remotePath: (String) path on netstore to use as cluster dir
'''
def create_cluster_dir(remotePath):

    # create a dir on netstore, name after root node
    # do it on netstore
    cmds = ['mkdir -p -m 0777 /netstore/' + remotePath]
    for cmd in cmds:
        run_system_cmd(cmd)
        #info("System command:: {}".format(cmd))
        #os.system(cmd)

'''
    Configure a node to be part of a cluster
    by generating its default.cfg with a nodelist,
    and bringing up the node

    :param node: (String) ip of node
    :param clusternodes: (list of Strings) list of IPs of all the nodes in the cluster
        ORDER OF THIS LIST IS IMPORTANT.
        clusternodes[0] : root node (node 0)
        clusternodes[1] : node1
        ... etc
    :param remoteClusterStoragePath: remote path on netstore that acts as shared storage for the nodes

'''
def configure_cluster_node(node, clusternodes, remoteClusterStoragePath):

    info("\nConfigure cluster node of {} of cluster nodes: {}\n".format(node, clusternodes))

    info("get local path to shared storage {}".format(remoteClusterStoragePath))
    local_cluster_storage_dir = setup_cluster_storage(node, remoteClusterStoragePath)
    #mount_shared_cluster_storage(node, remoteClusterStoragePath, CLUSTER_DIR_VM)

    info("generate cluster template file...")
    generate_cluster_template_file(node, clusternodes, local_cluster_storage_dir)

'''
    Generate template file for node
    (/etc/xcalar/default.cfg file, on the node)

    :param node: (String) ip of node to generate cfg file for
    :clusternodes: list of Strings: list of ips of nodes in the cluster
        ORDER IS IMPORTANT
        clusternodes[0] : root node (node 0)
        clusternodes[1] : node1
        ... etc  <that's how the shell script being called should work>
    :param xcalarRoot: (String) local path on the node to shared storage
        (val you want for Constants.XcalarRootCompletePath in the cg file)
'''
def generate_cluster_template_file(node, clusternodes, xcalarRoot):

    info("\nGenerate /etc/xcalar/default.cfg file for node {}, set with cluster nodes {}\n".format(node, clusternodes))

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

    info("\nDetermine local path VM {} should use to for xcalar home "
        " (Constants.XcalarRootCompletePath var in  /etc/xcalar/default.cfg".format(node))
    localPath = None

    '''
        Check if netstore already mounted on the VM.
        If so, local patha lready exists.
    '''
    alreadyMountedCheckPath = "/netstore/" + remotePath
    if path_exists_on_node(node, alreadyMountedCheckPath):
        info("Netstore already mounted... use {} as local path to shared storage".format(alreadyMountedCheckPath))
        return alreadyMountedCheckPath
    # netstore is not mounted.
    # mount and return the local path that results.
    # please try a couple times the mount command, it fails periodically
    localPath = CLUSTER_DIR_VM
    tries = 5
    info("Netstore not yet mounted on this vm")
    while tries:
        try:
            mount_shared_cluster_storage(node, remotePath, localPath)
            break
        except:
            info("Hit an issue when trying to mount netstore on vm... try again")
            time.sleep(5)
            tries -= 1
    if not tries:
        raise RuntimeError("\n\nERROR: I was not able to mount netstore on node {}; "
            " i kept hitting an exception\n".format(node))

    # regardless which path you went down... make sure it exists now on the VM!
    if path_exists_on_node(node, localPath):
        return localPath

'''
    Mount a directory on Netstore provisioned for shared cluster storage,
    on a cluster node.

    :param node: (String)
        IP of node to mount the storage space on
    :param remotePath: (String)
        Path on netstore, to remote shared storage space
'''
def mount_shared_cluster_storage(node, remotePath, localPath):

    info("\nMount remote Netstore dir {} on node {} as shared storage,"
        " at {}\n".format(remotePath, node, localPath))

    '''
        Check if netstore already mounted on the VM.
        If so do not need to mount.
    '''

    cmds = [
        ['systemctl restart autofs'],
        ['mkdir -p ' + localPath],
        ['chown xcalar:xcalar' + ' ' + localPath, 60],
        ['mount -o bind /netstore/' + remotePath + ' ' + localPath]
    ]

    run_ssh_cmds(node, cmds)

'''
    Check if a path exists on a node
    by SSHing and trying to cd to that path

    :param node: (String) ip of node to check path on
    :param path: (String) path to check on the node
'''
def path_exists_on_node(node, path):

    tries=25
    while tries:
        try:
            status, output = run_ssh_cmd(node, 'ls ' + path, timeout=10)
            return True
        except Exception as e:
            info("Hit an exception trying to ls to {} (netstore) on {}... Will try again in case automount issue...".format(path, node))
            tries -= 1
            time.sleep(5)

    if not tries:
        info("Error each time tries 'ls {}'; assuming not mounted and returning False".format(path))
        return False

'''
    get priority of clusters to try.
    Can pass an optional arg that will force a particular cluster
    to front of priority list.
    if that cluster is not valid will raise exception

    :param prioritize: (optional String)
        if given, should be a valid cluster name with template.
        In the list returned, will prioritize this cluster by setting as first el in the list
        (so that if caller of this method trying VM provisioning on clusters by iterating
        through list will end up trying that one first. For use case, that user wants
        to --tryotherclusters but would want to try on the default cluster or one they passed in
        with --ovirtcluster option first, others are just backup in case that one fails)
'''
def get_cluster_priority(prioritize=None):

    # try the clusters in this order
    clusterPriority = ['einstein-cluster2', 'feynman-dc', 'node3-cluster', 'node2-cluster', 'node4-cluster', 'node1-cluster']
    validClusters = []
    mapping = get_template_mapping() # get the official template mapping
    if prioritize:
        if prioritize in mapping:
            validClusters.append(prioritize)
        else:
            raise RuntimeError("\n\nERROR: Trying to prioritize {}, but it is not a valid cluster\n"
                "(dev: Is it a new cluster; have you added entry in to get_template_mapping for it?)\n".format(prioritize))
    for orderedcluster in clusterPriority:
        if orderedcluster != prioritize and orderedcluster in mapping:
            validClusters.append(orderedcluster)
    return validClusters

def get_template_mapping():

    return {
        'einstein-cluster2': 'ovirt-cli-tool-einstein-template',
        'feynman-dc'   : 'el7-template-1',
        'node2-cluster': 'ovirt-cli-tool-node2-template',
        'node3-cluster': 'ovirt-cli-tool-node3-template',
        'node4-cluster': 'ovirt-cli-tool-node4-template',
    }

'''
    Return name of template and cluster template is on,
    depending on what args requestesd (RAM, num cores, etc.)
'''
def get_template(ovirtcluster):

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
    if ovirtcluster in template_mapping.keys():
        ## todo - there should be templates for all the possible ram/cores/etc configs
        return template_mapping[ovirtcluster]
    else:
        raise AttributeError("\n\nERROR: No template found to use on ovirt node {}."
            "\nValid nodes with templates: {}\n".format(ovirtcluster, ",".join(template_mapping.keys())))

'''
        SYSTEM COMMANDS
'''


'''
    scp a file from the local machine to a remove machine
    @node ip of remote machine to copy file on to
    @localfilepath filepath of the file on the local machine
    @remotefilepath filepath where to put the file on the remote machine
'''
def scp_file(node, localfilepath, remotefilepath, keyfile=OVIRT_KEYFILE_DEST):

    info("\nSCP: Copy file {} from host, to {}:{}".format(localfilepath, node, remotefilepath))

    # do not need -i keyfile if puppet is set up
    cmd = 'scp -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no ' + localfilepath + ' root@' + node + ':' + remotefilepath
    run_system_cmd(cmd)

def run_ssh_cmds(host, cmds):

    info("\nSend cmds to {} via SSH.  cmd list: {}".format(host, str(cmds)))

    # run the cmds one by one.  it will create a new session each time
    errorFound = False
    for cmd in cmds:
        time.sleep(5)
        status = None
        extraops = {}
        if len(cmd) > 1:
            if cmd[1]:
                extraops['timeout'] = cmd[1]
            if len(cmd) > 2:
                extraops['valid_exit_codes'] = cmd[2]
        status, output = run_ssh_cmd(host, cmd[0], **extraops)

def run_ssh_cmd(host, command, port=22, user='root', bufsize=-1, keyfile=OVIRT_KEYFILE_DEST, timeout=120, valid_exit_codes=[0], pkey=None):
    # get list of valid codes
    info("\nssh {}@{}".format(user, host))
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(hostname=host, port=port, username=user, key_filename=keyfile)#, key_filename=key_filename, banner_timeout=10)
    info("connected...".format(host))
    chan = client.get_transport().open_session()
    chan.settimeout(timeout)
    chan.set_combine_stderr(True)
    chan.get_pty()
    info("[{}@{}  ~]# {}".format(user, host, command))
    chan.exec_command(command)
    stdout = chan.makefile('r', bufsize)
    stdout_text = stdout.read()
    info("stdout:\n\t{}".format(stdout_text))
    status = int(chan.recv_exit_status())
    info("status: {}".format(status))
    if status not in valid_exit_codes:
        info("stdout text:\n{}\n\nEncountered invalid exit status running SSH cmd {} on host {}!  (See above stdout)  Valid codes: {}".format(stdout_text, command, host, ', '.join(str(x) for x in valid_exit_codes)))
        raise RuntimeError("error in ssh cmd")
    client.close()
    return status, stdout_text.decode("utf-8")

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
        info(" $ {}".format(cmd))
        cmdout = subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True)
    except subprocess.CalledProcessError as e:
        info("Stderr: {}\n\nGot error when running sys command {}:\n{}".format(str(e.stderr), cmd, str(e.output))) # str on output in case None
        sys.exit(e.returncode)

    '''
    info("~:$ {}".format(cmd))
    os.system(cmd)
    '''

'''
    Run a shell script on a node

    :param node: IP of node to run shell script on
    :param path: filepath (on node) of shell script
    :param args: list of positional args to supply to shell script

'''
def run_sh_script(node, path, args=[], timeout=120, tee=False):

    info("\nRun shell script {} on node {}...\n".format(path, node))

    shellCmd = '/bin/bash ' + path + ' ' + ' '.join(args)
    if tee:
        filename = os.path.basename(path)
        shellCmd = shellCmd + ' | tee ' + filename + 'log.log'
    cmds = [['chmod u+x ' + path], [shellCmd, timeout]]
    run_ssh_cmds(node, cmds)

'''
    Given a list of multiprocessing:Process objects,
    wait until all the Process objects have completed.

    :procs: list of multiprocessing.Process objects representing the processes to monitor
    :timeout: how long (seconds) to wait for ALL processees
        in procs to complete, before timing out
    :valid_exit_codes: valid exit codes to come back from the process; list of ints
'''
def process_wait(procs, timeout=600, valid_exit_codes=[0]):

    numProcsStart = len(procs)

    # wait for all the processes to complete
    while procs and timeout:
        info("\t\t:: Check processes... ({} processes remain)".format(len(procs)))
        for i, proc in enumerate(procs):
            if proc.is_alive():
                time.sleep(1)
                timeout -= 1
            else:
                exitcode = proc.exitcode
                if exitcode not in valid_exit_codes:
                    raise ChildProcessError("Encountered invalid exit code, {} in a forked child process.  Valid exit codes for these processes: {}".format(exitcode, ', '.join(str(x) for x in valid_exit_codes)))
                del procs[i]
                break

    if timeout:
        info("All processes completed with 0 exit code")
    else:
        raise TimeoutError("Timed out waiting for processes to complete! {}/{} processes remain!".format(len(procs), numProcsStart))

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
def display_summary(vmids, ram, cores, ovirt_cluster, installer=None, clustername=None):

    summary_header = "\n\n=====================================================\n" \
            "------------ Your Ovirt VMs are ready!!! ------------\n" \
            "|\n| " + str(len(vmids)) + " VMs were created.\n" \
            "|\n| The VMs have the following specs:\n" \
            "|\tRAM (GB)     : " + str(ram) + "\n" \
            "|\t#  Cores     : " + str(cores)
    if installer:
        summary_header = summary_header + "\n|\tInstaller    : " + str(installer)
    #summary_str = summary_str + "\n|\tOvirt cluster: {}".format(ovirt_cluster) # it might have gone to another cluster. need to check through sdk

    # get the ips from the ids
    vmips = [get_vm_ip(vmid) for vmid in vmids]

    vm_ssh_creds = "|\tssh creds: jenkins/" + JENKINS_USER_PASS

    summary_str = "|\n=====================THE VMS=========================\n|"
    for i, vmid in enumerate(vmids):
        vmip = get_vm_ip(vmid)
        vmname = get_vm_name(vmid)
        # if multiple vms put a separator line between them
        if len(vmids) > 1 and i > 0:
            summary_str = summary_str + "\n|      --------------------------------------"
        summary_str = summary_str + "\n|\t Hostname: " + vmname + "\n" \
                                    "|\t IP      : " + vmip + "\n" + vm_ssh_creds
        if installer:
                summary_str = summary_str + "\n|\n|\tAccess URL: https://{}:8443".format(vmip) + "\n" \
                "|\tUsername (login page): " + LOGIN_UNAME + "\n" \
                "|\tPassword (login page): " + LOGIN_PWORD

    if installer:
        summary_str = summary_str + "\n| License key: \n|\n" + LICENSE_KEY

    clussumm = ""
    if clustername:

        clusternodedata = validate_cluster(vmips)
        info("node data: " + str(clusternodedata))

        # get node 0 for access URL
        if not '0' in clusternodedata:
            raise ValueError("No '0' entry in cluster node data: {}".format(clusternodedata))
        node0ip = clusternodedata['0']

        clussumm = "\n|\n=================== CLUSTER INFO ====================\n" \
            "|\n| Your VMs have been formed in to a cluster.\n" \
            "|\n| Cluster name: " + clustername  + "\n" \
            "| Access URL:\n|\thttps://" + node0ip + ":8443\n" \
            "|\tLogin page Credentials: " + LOGIN_UNAME + " \ " + LOGIN_PWORD + "\n" \
            "|\n ------------------------------------------\n"
        for nodenum in clusternodedata.keys():
            # get the name of the VM
            ip = clusternodedata[nodenum]
            vmname = get_vm_name(get_vm_id(ip))
            clussumm = clussumm + "|\n| Cluster Node" + nodenum + " is vm " + vmname + " [ip: " + ip + "]\n"
        clussumm = clussumm + "|\n ------------------------------------------\n"


    summary_str = summary_str + clussumm + "\n|\n=====================================================" \
                                        "\n-----------------------------------------------------\n"

    # print each of the vm ids to stdout
    info("\n")
    for ip in vmips:
        print(ip)

    info("SUMMARY START") # will get for thsi
    info("{}\n{}".format(summary_header, summary_str))
    info("\nSUMMARY END")

'''
    Check if this node is part of a cluster

    :param ip: (String) ip of node

    :returns: True if part of cluster, False otherwise
'''
def is_cluster_node(ip):

    # check cfg file to see if this is part of a cluster
    pass

'''
    Check if cluster is up from the perspective of a given node

    :param ip: (String) ip of the node

    :returns: True if cluster up from this node, False otherwise
'''
def is_cluster_up(ip):

    info("\nCheck if cluster is up from perspective of node {}".format(ip))

    cmd = '/opt/xcalar/bin/xccli -c version'
    status, output = run_ssh_cmd(ip, cmd)
    info("\n\nOUTPUT:\n\n" + output)
    if 'error' in output.lower():
        info("Cluster is not up from perspective of node with ip: {}."
            "\nOutput of {} "
            "(was used to determine cluster status):\n{}".format(ip, cmd, output))
        return False

    # right now determining cluster is up if not finding error
    info("Cluster is up from perspective of node with ip: {}"
        "\n(Used output of {} to determine; did not find error string so determined up."
        "\ncmd output was: {}".format(ip, cmd, output))
    return True

'''
    Log in to each cluster node,
    and make sure its node0, node1, etc. is showing
    in order specified
'''
def validate_cluster(clusterips):

    info("validate cluster nodes {} ".format(clusterips))

    currip = None
    curriplist = None
    for i, ip in enumerate(clusterips):

        # check if cluster showing up through this node
        if not is_cluster_up(ip):
            raise RuntimeError("Cluster is NOT up from the perspective of node {}".format(ip))

        # get list of ips and check against last node's list
        nextiplist = extract_cluster_node_ips(ip)
        info("\n\nNode ip list for {}:\n{}".format(ip, nextiplist))
        if i > 0:
            # make sure it matches against last
            for nodeidentifier in nextiplist.keys():
                # make sure same nodenum with ip in last list
                if curriplist[nodeidentifier] != nextiplist[nodeidentifier]:
                    raise ValueError("\n\nNode lists among two nodes in the cluster do not match!\n"
                        "Node list for {}:\n\t{}\n"
                        "Node list for {}:\n\t{}\n".format(currip, curriplist, ip, nextiplist))

        currip = ip
        curriplist = nextiplist

    # return one of the ip lists
    return curriplist

'''
    SSH in to the cluster node,
    and retrieve list of node 0, node 1, etc. IPs from its default.cfg file
'''
def extract_cluster_node_ips(ip):

    configfilepath = '/etc/xcalar/default.cfg'
    info("\nExtract cluster node data from {}  file on {}".format(configfilepath, ip))

    status, output = run_ssh_cmd(ip, 'cat ' + configfilepath)

    nodeips = {}

    # get num nodes in the cluster
    numnodes = None
    nodenumreg = re.compile('.*Node\.NumNodes=(\d+).*', re.DOTALL)
    matchres = nodenumreg.match(output)
    if matchres:
        info("found match")
        numnodes = int(matchres.groups()[0])
    else:
        raise AttributeError("\n\nFound no entry for number of nodes in {}\n".format(configfilepath))

    # parse all the node data
    nodeipdata = re.compile('.*Node\.(\d+)\.IpAddr=([\d\.]+).*')
    for line in output.split('\n'):
        info("Next line: {}".format(line))
        matchres = nodeipdata.match(line)
        if matchres:
            info("Found match of node data on line : {}".format(line))
            # get the node # and ip
            captures = matchres.groups()
            nodenum = captures[0]
            nodeip = captures[1]

            if nodenum in nodeips:
                raise AttributeError("Node{} already registered to ip {}".format(nodenum, nodeip))
            info("add entry {}:{}".format(nodenum, nodeip))
            nodeips[nodenum] = nodeip

    # make sure same num nodes as what you got for number nodes
    if len(nodeips.keys()) != numnodes:
        raise AttributeError("config file said there are {} nodes, "
            "but found {} when parsing".format(numnodes, len(nodeips)))

    return nodeips

'''
    I know this is only doing one thing (the ssh key) but wanted to make
    a script setup which might have more added to it.
'''
def setup():

    '''
    Ovirt SSH key:
    not all users have their ssh pub key in the template the VMs being generated from.
    therefore, have made a ssh key just for Ovirt which has root perms in the templates,
    and will supply it when making ssh calls.
    For scp the private key needs to have stricter permissions so need to chmod.
    but dont want chmod to result in it showing up in users git status.
    so transfer the private key to .ssh/ and chmod there.  the ssh calls will send
    key in .ssh/
    '''

    # if this keyfile already exists and it's low permission,
    # you're going to need to sudo to cp and change the permissions.
    # but if you sudo it will set the user as root and then will fail
    # to authenticate.  but if exists not sure if its acceptible perm
    # level, so delete it and copy it back in fresh
    # (todo - when make cleanup remove)
    cmds = ['cp ' + OVIRT_KEYFILE_SRC + ' ' + OVIRT_KEYFILE_DEST,
            'chmod 400 ' + OVIRT_KEYFILE_DEST]

    if os.path.exists(OVIRT_KEYFILE_DEST):
        info("Ovirt key file {} already exists, remove".format(OVIRT_KEYFILE_DEST))
        cmds.insert(0, 'sudo rm ' + OVIRT_KEYFILE_DEST)
    for cmd in cmds:
        run_system_cmd(cmd)

def validateparams(args):

    licfilepath = args.licfile
    installer = args.installer
    basename = args.vmbasename

    if args.count:
        if args.count > MAX_VMS_ALLOWED or args.count <= 0:
            raise ValueError("\n\nERROR: --count argument must be an integer between 1 and {}\n"
                "(The ovirt tool will provision that number of new VMs for you)".format(MAX_VMS_ALLOWED))

        # validate the basename they gave for the cluster
        if not basename:
            errmsg = ""
            if args.count == 1:
                errmsg = "\n\nPlease supply a name for your new VM using --vmbasename=<name>\n"
            else:
                errmsg = "\n\nPlease supply a basename for your requested VMs using --vmbasename=<basename>\n" \
                    "(The tool will name the new VMs as : <basename>-vm0, <basename>-vm1, .. etc\n"
            if not args.nocluster:
                errmsg = errmsg + "The --vmbasename value will become the name of the created cluster, too.\n"
            raise ValueError(errmsg)
        else:
            # validate the name they supplied is all lower case and contains no _ (because will be setting hostname of the VMs to the VM name)
            if any(filter(str.isupper, args.vmbasename)) or '_' in args.vmbasename:
                raise ValueError("\n\nERROR: --vmbasename value must be all lower case letters, and may not contain any _ chars\n")

            '''
                if the basename begins with one of Ovirt's search refining keywords
                (a string you can type in the GUI's search field to refine a search, ex. 'cluster', 'host')
                then the vms_service.list api will not work.
                this leads to confusing results which are not immediately obvious what's going on
            '''
            for ovirtSearchFilter in PROTECTED_KEYWORDS:
                if args.vmbasename.startswith(ovirtSearchFilter):
                    raise ValueError("\n\nERROR: --vmbasename can not begin with any of the values: {} (These are protected keywords in Ovirt)".format(PROTECTED_KEYWORDS))

        if args.noinstaller:
            if args.installer:
                raise AttributeError("\n\nERROR: You have specified not to install xcalar with the --noinstaller option,\n"
                    "but also provided an installation path with the --installer option.\n"
                    "(Is this what you intended?)\n")
        else:

            ''' installer:
                make sure URL can curl
            '''
            installerheader = 'http://'
            defaultinstaller = installerheader + 'netstore/builds/byJob/BuildTrunk/xcalar-latest-installer-prod'
            if not installer:
                installer = defaultinstaller
            if installer.startswith(installerheader):
                # make sure they have given the regular RPM installer, not userinstaller
                filename = os.path.basename(installer)
                if 'gui' in filename or 'userinstaller' in filename:
                    raise ValueError("\n\nERROR: Please supply the regular RPM installer, not the gui installer or userinstaller\n")
            else:
                raise ValueError("\n\nERROR: --installer arg should be an URL for an RPM installer, which you can curl.\n"
                    "(If you know the <path> to the installer on netstore, then the URL to supply would be: --installer=http://netstore/<path>\n"
                    "Example: --installer={})\n".format(defaultinstaller))

            '''
                license files for xcalar.
                If they plan on installing xcalar on the new VMs,
                and did not supply lic of pub file options,
                look in their cwd
            '''
            info("\nMake sure license keys are present....")

            scriptcwd = os.path.dirname(os.path.realpath(__file__))
            if not licfilepath:
                licfilepath = LICFILENAME
                info("\tYou did not supply --licfile option... will look in cwd for Xcalar license file...")
            if not os.path.exists(licfilepath):
                raise FileNotFoundError("\n\nERROR: File {} does not exist!\n"
                    " (Re-run with --licfile=<path to latest licence file>, or,\n"
                    " copy the file in to the dir the tool is being run from\n"
                    "Try this::\n\tcp $XLRDIR/src/data/XcalarLic.key {}\n".format(licfilepath, scriptcwd))

    else:
        '''
            if not trying to create vms,
            make sure at least runing to remove VMs then, else nothing to do
        '''
        if not args.delete:
            raise AttributeError("\n\nERROR: Please re-run this script with arg --count=<number of vms you want>\n")

    return int(args.ram), int(args.cores), args.ovirtcluster, licfilepath, installer, basename

'''
    Check if a String is in format of ip address
    Does not ping or make sure valid, just checks format

    :param string: String to check if its an ip address

    :returns: True if ip address, False otherwise
'''
def ip_address(string):

    try:
        socket.inet_aton(string)
        info("{} is in valid IP address format".format(string))
        return True
    except Exception as e:
        info("{} not showing as a valid IP address".format(string))
        return False


if __name__ == "__main__":

    '''
        Parse and validation cmd arguments
    '''

    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--count", type=int, default=0, help="Number of VMs you'd like to create")
    parser.add_argument("--vmbasename", type=str, help="Basename to use for naming the new VMs (will create VMs named <basename>-vm0, <basename>-vm1, .., <basename>-vm(n-1) )")
    parser.add_argument("--cores", type=int, default=4, help="Number of cores per VM.")
    parser.add_argument("--ram", type=int, default=8, help="RAM on VM(s) (in GB)")
    parser.add_argument("--nocluster", action='store_true', help="Do not create a Xcalar cluster of the new VMs.")
    parser.add_argument("--installer", type=str, #default='builds/Release/xcalar-latest-installer-prod',
        help="URL to RPM installer to use for installing Xcalar on your VMs.  (Should be an RPM installer you can curl, example: http://netstore/<netstore's path to the installer>). \nIf not supplied, will use RPM installer for latest BuildTrunk prod build.)")
    parser.add_argument("--noinstaller", action="store_true", default=False, help="Don't install Xcalar on provisioned VMs")
    parser.add_argument("--ovirtcluster", type=str, default='einstein-cluster2', help="Which ovirt cluster to create the VM(s) on.  Defaults to einstein-cluster2")
    parser.add_argument("--tryotherclusters", action="store_true", default=False, help="If supplied, then if unable to create the VM on the given Ovirt cluster, will try other clusters on Ovirt before giving up")
    parser.add_argument("--licfile", type=str, help="Path to a XcalarLic.key file on your local machine (If not supplied, will look for it in cwd)")
    parser.add_argument("--puppet_role", type=str, default="jenkins_slave", help="Role the VM should have (Defaults to jenkins_slave)")
    parser.add_argument("--puppet_cluster", type=str, default="ovirt", help="Role the VM should have (Defaults to jenkins_slave)")
    parser.add_argument("--delete", type=str, help="Single VM or comma separated String of VMs you want to remove from Ovirt (could be, IP, VM name, etc).")
    parser.add_argument("--user", type=str, help="Your SSO username (no '@xcalar.com')")
    parser.add_argument("-f", "--force", action="store_true", default=False, help="Force certain operations such as provisioning, delete, when script would fail normally")

    args = parser.parse_args()

    ram, cores, ovirtcluster, licfilepath, installer, basename = validateparams(args)
    FORCE = args.force

    # script setup
    setup()

    #open connection to Ovirt server
    CONN = open_connection(user=args.user)

    '''
        remove vms first if requested, to free up resources
    '''
    deletevms = []
    if args.delete:
        deletevms = args.delete.split(',')
        remove_vms(deletevms)

    ''''
        main driver
    '''

    #  spin up number of vms requested
    vmids = []
    clustername = None
    if args.count:
        vmids = provision_vms(int(args.count), basename, ovirtcluster, args.puppet_role, args.puppet_cluster, convert_mem_size(ram), cores, user=args.user, tryotherclusters=args.tryotherclusters) # user gives RAM in GB but provision VMs needs Bytes

        if not args.noinstaller:
            # if you supply a value to 'createcluster' arg of initialize_xcalar,
            # then once xcalar install compled on all nodes will form the vms in
            # to a cluster by that name
            if not args.nocluster and int(args.count) > 1:
                clustername = basename
            initialize_xcalar(vmids, licfilepath, installer, createcluster=clustername)

        '''
            display a useful summary to user which has IP, VM names, etc.
        '''
        display_summary(vmids, ram, cores, ovirtcluster, installer=installer, clustername=clustername) #, removed=deletevms)

        # reboot all of the nodes in parallel
        reboot_nodes(vmids)

    # close connection
    close_connection(CONN)

