#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""

Tool to spin up VMs on Ovirt and create Xcalar clusters

@help:
    python ovirttool.py --help

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
from __future__ import absolute_import, division, print_function
from future.utils import raise_from # re-raise exceptions python3 way in python2.7
from builtins import input # for input to work on python2.7 and python3

import ovirtsdk4 as sdk
import ovirtsdk4.types as types

import argparse
import getpass
import logging
import random
import datetime
import string
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

MAX_VMS_ALLOWED=1024

DEFAULT_SSH_USER='root' # what tool will be ssh'ing as.

DEFAULT_OVIRT_CLUSTER="ovirt-node-1-cluster"
#DEFAULT_PUPPET_CLUSTER="ovirt"
DEFAULT_PUPPET_ROLE="jenkins_slave"
DEFAULT_CORES=4
DEFAULT_RAM=8

REBOOT_TIMEOUT=500 # seconds to wait before timing out after waiting to be able to ssh to a VM after 'reboot -h'
SHUTDOWN_TIMEOUT = 600 # seconds to wait before timing out on vms to shut down
POWER_ON_TIMEOUT = 120 # seconds to wait before timing out waiting for a vm to power on
IP_ASSIGN_TIMEOUT = 800 # seconds to wait before timing out waiting for IP to be assigned to newly powered on VM
PUPPET_SETUP_TIMEOUT = 2700 # seconds to wait before timing out puppet setup/puppet agent run

NETSTORE_IP='10.10.1.107'
XUID = '1001' # xcalar group uid. hacky fix later
JENKINS_USER_PASS = "jenkins" # password to set for user 'jenkins' on provisioned VMs
LOGIN_UNAME = "admin"
LOGIN_PWORD = "admin"
LICENSE_KEY = "H4sIAAAAAAAAA22OyXaCMABF93yF+1YLSKssWDAKiBRR1LrpCSTWVEhCCIN/Xzu46/JN575AIA4EpsRQJ7IU4QKRBsEtNQ4FKAF/HAWkkBJOYVsID1S4vP4lIwcIMEpKIE6UV/fK/+EO8eYboUy0G+RuG1EQZ4f3w4smuQPDvzduQ2Sosjofm4yPp7IUU4hs2hJhKLL6LGUN4ncpS6/kZ3k19oATKYR54RKQlwgagrdIavAHAaLlyNALsVwhk9nHM7apnvbrc73q9BCh2duxPZbJ4GtPpjy4U6/uHKrBU6U4ijazYekVRDBrEyvJcpUTD+2UB9RfTNtleb0OPbjFl21PqgDvFStyQ2HFrtr7rb/2mZDpYtqmGasTPez0xYAzkeaxmaXFJtj0XiTPmW/lnd5r7NO2ehg4zuULQvloNpIBAAA="

OVIRT_TEMPLATE_MAPPING = {
    'ovirt-node-1-cluster': 'el7-template-20180816',
    'einstein-cluster2': 'ovirt-tool-einstein-updated',
    'node2-cluster': 'ovirt-cli-tool-node2-template',
    'node3-cluster': 'ovirt-cli-tool-node3-template'
}

SCRIPT_DIR = os.path.dirname(os.path.realpath(sys.argv[0]))

TMPDIR_LOCAL='/tmp/ovirt_tool' # tmp dir to create on local machine running python script, to hold pem cert for connecting to Ovirt
TMPDIR_VM='/tmp/ovirt_tool' # tmp dir to create on VMs to hold helper shell scripts, lic files (dont put timestamp because forking processes during install processing)
CLUSTER_DIR_VM='/mnt/xcalar' # if creating cluster of the VMs and need to mount netstore, will be local dir to create on VMs, to mount shared storage space to.

# location of puppet lock file on a VM to check if puppet service
# is running (won't run puppet agent if this file present)
PUPPET_LOCK_FILE='/var/run/puppetlabs/agent_catalog_run.lock'

OVIRT_KEYFILE_SRC = 'id_ovirt' # this a file to supply during ssh.  need to chmod it for scp but dont want it to show up in users git status, so this its loca nd will move it to chmod
home = os.path.expanduser('~') # '~' gives issues with paramiko; expand to home dir, this swill work cross-platform
OVIRT_KEYFILE_DEST = home + '/.ssh/id_ovirt'

def generateRandomString(length=5):
    return ''.join([random.choice(string.ascii_letters + string.digits) for n in range(length)])

OVIRT_SHELL_LOGS_DIR = '/tmp/ovirtShellScriptLogs_' + generateRandomString() # dir on created VMs to hold redirected shell script output

CONN=None
LICFILENAME='XcalarLic.key'
# helper scripts - they should be located in dir this python script is at
DEFAULT_ADMIN_FILE = 'defaultAdmin.json'
INSTALLER_SH_SCRIPT = 'e2einstaller.sh'
TEMPLATE_HELPER_SH_SCRIPT = 'templatehelper.sh'
ADMIN_HELPER_SH_SCRIPT = 'setupadmin.sh'

FORCE = False # a force option will allow certain operations when script would fail otherwise (use arg)

# Ovirt GUI search bar has search refining keywords
# if you try to name a VM starting with one of these, vms_service.list api will
# fail if that name is the identifier.  add these here so can fail on param validation
# (else the script will fail after provisioning and it is not obvious at all why its failing)
PROTECTED_KEYWORDS = ['cluster', 'host', 'fdqn', 'name']

# chars that are disallowed in VM names
ILLEGAL_VMNAME_CHARS = ['.', '_']

class NoIpException(Exception):
    pass

class TimeoutError(Exception): # built in python3 but not python2.7
    pass

class CantFindClusterError(Exception):
    pass

class NoMatchingVmsException(Exception):
    pass

class NotUniqueVmIdentifierException(Exception):
    pass

class ShellError(Exception):
    def __init__(self, cmd, node, status, stdout, stderr, summary):
        self.cmd = cmd
        self.node = node
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.summary = summary

    def __str__(self):
        errStr = '''

>> shell command that caused error:
    {}

>> Run on node:
    {}

>> Returned Status:
    {}

>> stdout:

{}

>> stderr:

{}

'''.format(self.cmd, self.node, self.status, self.stdout, self.stderr)
        if self.summary:
            errStr += ">> Reason error thrown:\n\t{}".format(self.summary)
        return errStr

''' log methods to use in this script '''
def debug_log(string):
    loggit(string, level=1)
def info_log(string):
    loggit(string, level=0)
def warn_log(string):
    loggit(string, level=2)
''' don't call this one directly, use the aux methods above '''
def loggit(string, level=1):
    level_prefixes={0:"{}",1:"DEBUG: {}",2:"WARN: {}"}
    # timestamp
    st = datetime.datetime.utcnow()
    # split on any newline chars, and print each with the prefix
    for line in string.split("\n"):
        print("{} ".format(st) + level_prefixes[level].format(line), file=sys.stdout)

'''
    OVIRT SDK FUNCTIONS
'''

'''
    Generate n names for VMs which are not currently used in Ovirt,
    given some basename.  Will add random chars to the name to try to avoid
    re-using old hostnames of deleted VMs which would cause issues in puppet
    Returns as list
'''
def generate_vm_names(basename, n):
    vmNames = []
    uniqueBasename = None
    # keep trying random strings on basename until you hit a combo not in ovirt
    # don't check for exact equality when checking if in Ovirt - since will
    # append -vm0, -vm1, etc. to end of this.  this will return if there's any
    # vm in ovirt with this as a substring
    while not uniqueBasename or get_matching_vms(uniqueBasename):
        uniqueBasename = "{}-{}".format(basename, generateRandomString(4))
    for i in range(n):
        vmNames.append("{}-vm{}".format(uniqueBasename, n))
    return vmNames

'''
    wait until Ovirt is showing a valid ip for a vm.
    return the ip.
    (This is useful if you've just created or rebooted a VM,
    and the VM itself is up, but need to wait for an IP to be
    assigned to the VM by Ovirt.)

    :vmid: Ovirt id for the VM
    :timeout: time in seconds to wait for the IP to be assigned

    :returns: IP address if found
    :throws: NoIpException if no valid ip found after timeout
'''
def wait_for_ip(vmid, timeout):
    debug_log("Wait until IP displaying in Ovirt for a VM")
    timeout_remaining = timeout
    sleep_seconds_between_checks = 5
    while timeout_remaining:
        try:
            debug_log("try to get vm ip")
            assigned_ip = get_vm_ip(vmid)
            debug_log("\tIP {} assigned!".format(assigned_ip))
            return assigned_ip
        except NoIpException as e: # let other Exception fail
            # not available yet
            debug_log("still no ip")
            time.sleep(sleep_seconds_between_checks)
            timeout_remaining -= sleep_seconds_between_checks
    if not timeout_remaining:
        raise NoIpException("Never got IP (might increase timeout, waited {} " \
            "seconds.  Might try increasing timeout)".format(timeout))
'''
    wait for a VM with a locked image state to become unlocked
'''
def wait_for_image_unlock(vmid, image_unlock_timeout=100):
    vm_service = get_vm_service(vmid)
    name = get_vm_name(vmid)
    info_log("Wait for image of {} to be unlocked (if locked) (2-3 minutes)".format(name))

    timeout = image_unlock_timeout
    while timeout:
        vm = vm_service.get()
        if vm.status == types.VmStatus.IMAGE_LOCKED:
            time.sleep(2)
            timeout-=1
            debug_log("Stil LOCKED.  Wait.")
        else:
            debug_log("Image is NOT locked.")
            return True
    if not timeout:
        raise TimeoutError("Timed out waiting for Image to unlock on {}. " \
            " (Waited {} seconds)".format(name, image_unlock_timeout))

'''
    wait for a VM to come up
'''
def wait_for_vm_to_come_up(vmid, power_on_timeout=POWER_ON_TIMEOUT):
    name = get_vm_name(vmid)
    info_log("Wait for {} to come up (2-3 minutes)".format(name))
    timeout_remaining = power_on_timeout
    sleep_seconds_between_checks = 5
    while timeout_remaining:
        if is_vm_up(vmid):
            debug_log("\t{} is up!".format(name))
            break
        else:
            time.sleep(sleep_seconds_between_checks)
            timeout_remaining -= sleep_seconds_between_checks
    if not timeout_remaining:
        raise TimeoutError("Started service on {}, but VM never came up!" \
            " Waited {} seconds".format(name, power_on_timeout))

'''
    checks if VM is in one of states expected if services
    has been successfully started
'''
def is_vm_in_post_service_start_state(vmid):
    debug_log("Check if vm is in a 'powering up' state...")
    vm_service = get_vm_service(vmid)
    powering_states=[types.VmStatus.UP, types.VmStatus.POWERING_UP, types.VmStatus.WAIT_FOR_LAUNCH]
    vm = vm_service.get()
    for power_on_state in powering_states:
        if vm.status == power_on_state:
            debug_log("VM in state: {} ; powering up!".format(vm.status))
            return True
    return False

'''
    get vm in a powering on state
'''
def start_vm(vmid):
    vm_service = get_vm_service(vmid)
    name = get_vm_name(vmid)

    # will error if service start attempted while in powering up state
    if is_vm_in_post_service_start_state(vmid):
        return True
    else:
        # can't start service if powering down; will fail
        info_log("Wait for any previous power downs to complete on {}".format(name))
        wait_for_service_to_come_down(vmid)

        info_log("Start service on {}".format(name))
        # try to catch memory exception
        try:
            # start the vm
            vm_service.start()
            debug_log("started service!")
        except Exception as e:
            # if the resource excpetion from Ovirt
            # want to raise that will handle it higher up in
            # provision_vm function
            if 'memory' in str(e):
                warn_log("Throwing memory exception: {}".format(str(e)))
            raise e

    # wait until state has changed
    timeout = 10
    while timeout:
        if is_vm_in_post_service_start_state(vmid):
            return True
        else:
            time.sleep(1)
            timeout-=1
    if not timeout:
        raise TimeoutError("Powered on {}, but not in powering up state".format(name))

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
        if waitForIP - the String of the IP that got assigned to the new VM

    :throws Exception if any stage not successfull
'''
def bring_up_vm(vmid, power_on_timeout=POWER_ON_TIMEOUT, ip_assign_timeout=IP_ASSIGN_TIMEOUT, waitForIP=None):

    vm_service = get_vm_service(vmid)
    name = get_vm_name(vmid)
    info_log("Bring up VM {}".format(name))

    if is_vm_up(vmid):
        # the api will throw exception if you try to start and it's in up state already
        debug_log("Vm {} is already up!  I will not start".format(name))
    else:
        # first make sure image not locked
        wait_for_image_unlock(vmid)
        start_vm(vmid)
        wait_for_vm_to_come_up(vmid, power_on_timeout=power_on_timeout)

    if waitForIP:
        info_log("Wait until IP has been assigned to {}".format(name))
        assignedIp = wait_for_ip(vmid, ip_assign_timeout)
        info_log("IP {} has been assigned to {}".format(assignedIp, name))
        return assignedIp

    info_log("VM {} successfully brought up.".format(name))

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

    info_log("Create a VM called '{}' on {}".format(name, cluster))
    debug_log("VM specs: {}\n\tOvirt cluster: {}\n\tTemplate VM  : {}\n\tRAM (bytes)  : {}\n\t# cores      : {}".format(name, cluster, template, ram, cores))

    # Get the reference to the "vms" service:
    vms_service = CONN.system_service().vms_service()
    debug_log("got vms service")

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
        debug_log("VM added...")

        # get id of the newly added vm (can't get from obj you just created.  need to get from vms service)
        vmid = get_vm_id("name=" + name)
        debug_log("\tid assigned: {}...".format(vmid))
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
        debug_log("Bring up {}...".format(vmid))
        # sometimes IP not coming up first time around.  restart and ty again
        triesleft = iptries
        assignedIp = None
        while triesleft:
            try:
                time.sleep(5)
                assignedIp = bring_up_vm(vmid, waitForIP=True)
                break
            except NoIpException:
                debug_log("WARNING: Timed out waiting for IP on new VM... will restart and try again...")
                triesleft -= 1
                stop_vm(vmid)

        if not assignedIp:
            raise RuntimeError("ERROR: Never got Ip for {}/[id:{}],\n"
                " even after {} restarts (dhcp issue?)\n".format(name, vmid, iptries))

        # IP came up, but make sure it is actually unique to this new VM for Ovirt (feynman issue)
        # args is search string to use in ovirt search bar; search by actual ip
        # else just supplying ip would return superstrings of that ip too
        matchingVMs = get_matching_vms("ip=" + assignedIp)
        if len(matchingVMs) > 1:
            info_log("IP that got assigned to {}, {}, " \
                "registered to another VM in Ovirt... " \
                "(probably due to Feynman outage) " \
                "going to delete vm and re-try".format(name, assignedIp))
            remove_vm(name, releaseIP=False) # set releaseIP as False -
                # since it's of no use as the issue is that the IP is being re-assigned!
            continue
        else:
            break

    if feynmanTries:
        debug_log("Successfully created VM {}, on {}!!".format(name, cluster))
        #\n\tIP: {}\n\tCluster: {}\n\tTemplate {}".format(myvmname, new_ip, cluster, template))
        return vmid
    else:
        raise RuntimeError("VM was being provisioned, but kept getting re-assigned "
            " IPs already registered with Ovirt.  Tried {} times before giving up!"
            .format(feynmanIssueRetries))

def setup_hostname(ip, name):

    debug_log("Set hostname of VM {} to {}".format(ip, name))
    fqdn = "{}.int.xcalar.com".format(name)
    run_ssh_cmd(ip, '/bin/hostnamectl set-hostname {}; echo "{} {} {}" >> /etc/hosts; service rsyslog restart'.format(name, ip, fqdn, name))
    run_ssh_cmd(ip, 'systemctl restart network', timeout=500)
    run_ssh_cmd(ip, 'systemctl restart autofs')

def get_hostname(ip):

    debug_log("Get hostname of VM {}".format(ip))
    status, stdout, stderr = run_ssh_cmd(ip, 'cat /proc/sys/kernel/hostname')
    debug_log("\tFound hostname: {}".format(stdout))
    return stdout.strip()

def reboot_node(ip, waitForVmToComeUp=True, reboot_timeout=REBOOT_TIMEOUT, ip_assign_timeout=IP_ASSIGN_TIMEOUT):

    vmid = get_vm_id(ip)
    try:
        run_ssh_cmd(ip, 'reboot -h')
    except Exception as e:
        debug_log("expect to hit exception after the reboot")

    if waitForVmToComeUp:
        debug_log("Wait for {} to come up from reboot...".format(ip))
        # wait a few seconds before initial ssh; immediately after reboot
        # was able to make the ssh call
        time.sleep(10)
        timeout_remaining=reboot_timeout
        seconds_to_sleep_between_checks=10
        while timeout_remaining:
            try:
                run_ssh_cmd(ip, 'echo hello')
                debug_log("{}is back up!".format(ip))
                break
            except Exception as e:
                if 'Unable to connect' in str(e):
                    debug_log("still unable to ssh...")
                    debug_log(e)
                    time.sleep(seconds_to_sleep_between_checks)
                    timeout_remaining-=seconds_to_sleep_between_checks
                else:
                    debug_log("Exception thrown waiting for {} to come up " \
                        " after reboot, for reason other than " \
                        "'Unable to connect'".format(ip))
                    raise e
        if not timeout_remaining:
            raise TimeoutError("Timed out waiting for {} to come up " \
                " after reboot.  Waited {} seconds".format(ip, reboot_timeout))

        # wait until IP is displaying again in ovirt
        assignedIp = wait_for_ip(vmid, ip_assign_timeout)
        if assignedIp != ip:
            debug_log("WARNING: node {} came up after reboot, but in Ovirt now is " \
                " assigned as IP {}".format(ip, assignedIp))

'''
    setup a node to be able to run puppet
'''
def setup_puppet(ip, puppet_role, puppet_cluster):
    debug_log("Setup puppet to run on {} as role {}".format(ip, puppet_role))
    cmds = [
        ['echo "role={}" > /etc/facter/facts.d/role.txt'.format(puppet_role)]
    ]
    if puppet_cluster:
        cmds.append(['echo "cluster={}" > /etc/facter/facts.d/cluster.txt'.format(puppet_cluster)])
    run_ssh_cmds(ip, cmds)

'''
    Run puppet agent -t -v on an IP, with option to do skip setup
    (in case puppet needs to be run multiple times)
    :puppet_role: required if setup True (puppet_cluster optional)

    NOTES:
     ++ make sure this is done AFTER hostname set up
     +++ you will NOT be able to SSH in to the VM (via 'run_ssh_cmd' function)
        once puppet is set up!  ovirt_key pubkey won't be authorized as root anymore
'''
def run_puppet_agent(ip, puppet_role=None, puppet_cluster=None, setup=True, puppet_timeout=PUPPET_SETUP_TIMEOUT):
    info_log("Run puppet agent on {} (10-25 minutes)".format(ip))
    if setup:
        if not puppet_role:
            raise RuntimeError("Specified to setup puppet before running "
                " puppet agent, but no puppet_role specified. "
                " (puppet_role required to setup puppet)")
        setup_puppet(ip, puppet_role, puppet_cluster)
    # run puppet agent
    # wait until 'lock file' is no longer present
    # (if running puppet agent more than once, the puppet service could be running;
    # puppet agent will fail until the service is no longer running)
    debug_log("(Check if lock file {} present before running "
        " puppet agent...)".format(PUPPET_LOCK_FILE))
    lockfileWait = 100
    while lockfileWait:
        if path_exists_on_node(ip, PUPPET_LOCK_FILE):
            time.sleep(10)
            lockfileWait -= 1
        else:
            break
    # still try to run puppet agent; if it fails, it fails...
    # once puppet is set up, will not be able to ssh with ovirt key any longer
    run_ssh_cmd(ip, '/opt/puppetlabs/bin/puppet agent -t -v', timeout=puppet_timeout, valid_exit_codes=[0, 2])

'''
    setup puppet on all nodes in parallel
'''
def enable_puppet_on_vms_in_parallel(vmids, puppet_role, puppet_cluster=None, puppet_agent_timeout=PUPPET_SETUP_TIMEOUT):

    debug_log("Setup puppet on all nodes in parallel")

    procs = []
    sleepBetween = 5
    sleepOffset = 0
    for vmid in vmids:
        ip = get_vm_ip(vmid)
        proc = multiprocessing.Process(target=run_puppet_agent, args=(ip,), kwargs={
            'setup': True,
            'puppet_role': puppet_role,
            'puppet_cluster': puppet_cluster,
            'puppet_timeout': puppet_agent_timeout
        })
        proc.start()
        procs.append(proc)
        sleepOffset+=sleepBetween

    # wait for the processes
    process_wait(procs)

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
        debug_log("{} bytes memory available on cluster {}".format(mem_available_this_cluster, cluster))

        # see how many VMs you could make with that
        consumes = math.floor(mem_available_this_cluster/ram)
        debug_log("{} vms could be consumed by cluster {}".format(consumes, cluster))

        # if it couldn't create any VMs at all, don't include in list returned
        if consumes:
            debug_log("Cluster {} could consume {} vms... add to useful clusters".format(cluster, consumes))
            useful_clusters.append(cluster)

        # update how many VMs left in request.
        # if that takes care of rest of VMs, guess is that enough available memory!
        # return list of useful clusters!
        vms_remaining = vms_remaining - consumes
        debug_log("{} would vms remain in request...".format(vms_remaining))
        if vms_remaining <= 0:
            # add rest of the clusters in (no harm for more resources)
            debug_log("Guess is clusters should be able to handle the VM request load (others could be using clusters though)")
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
    found_cluster = False

    hosts_service = CONN.system_service().hosts_service()
    hosts = hosts_service.list()
    for host in hosts:
        if host.status != types.HostStatus.UP:
            debug_log("Host {} is not UP.  Do not figure in to available memory estimates...".format(host.name))
            continue

        if host.cluster:
            # cluster attr is a link.  follow link to retrieve data about the cluster
            cluster = CONN.follow_link(host.cluster)
            # try to get the name
            if cluster.name and cluster.name == name:
                found_cluster = True
                debug_log("Host {} is part of requested cluster, {}".format(host.name, cluster.name))
                # add this hosts available memory to cnt
                if host.max_scheduling_memory:
                    debug_log("Host {}'s max scheduling memory (in bytes): {}".format(host.name, str(host.max_scheduling_memory)))
                    mem_found = mem_found + host.max_scheduling_memory

    if found_cluster:
        debug_log("Available memory found on cluster {}: {} bytes".format(name, mem_found))
        return int(mem_found)
    else:
        raise CantFindClusterError("Trying to determine available memory "
            "for ovirt cluster '{}', but can not find this cluster on any "
            "'Host' (see 'Host' tab in ovirt and for each row in the table, "
            "look at the 'cluster' column.  Can't find {} in any of those "
            "rows.)\n(have the names of any ovirt clusters "
            "changed?  Check that the keys in OVIRT_TEMPLATE_MAPPING are valid "
            "cluster names)\n".format(name, name))

'''
    returns list of VM objects matching a given identifier
    (This is equivalent to logging in to Ovirt, and typing
    this EXACT identifier string in the search bar, and returning a ovirtsdk4.type.Vm
    object for each matching row)

    :param identifier: String. search criteria you would type in the Ovirt search bar.

    :returns: list of ovirtsdk4.type.Vm objects, one for each
        vm matching the identifier string
        (if no matches returns empty list)
'''
def get_matching_vms(identifier):

    debug_log("Try to find VMs matching identifier {}".format(identifier))

    vms_service = CONN.system_service().vms_service()

    # search ovirt for vms matching the identifier
    # (value supplied to search attr is just like searching by that value in Ovirt GUI's search bar)

    # search attr must be type 'str'; handle differently in python2.7 vs. python3
    searchStr = pyString(identifier)
    matching_vms = vms_service.list(search=searchStr)
    if matching_vms:
        return matching_vms
    return []

'''
    Returns a string representation of a variable that's of type 'str',
    regardless if you are running python3 or python2.7

    (Reason: in python 3, str(<var>) will return a variable of type 'str',
    but in python2.7, if the variable is type 'unicode', would need to encode it explicitally
    However encoding in python3 will return type 'Byte', not 'str', so can't this for both.
    - ovirtsdk's search api requires search var must be type 'str' hence why this is needed.)
'''
def pyString(var):
    convertedVar = str(var)
    if sys.version_info[0] >= 3:
        return convertedVar
    return var.strip().encode('utf-8') # strip off formatting so it doesn't get encoded to literals

'''
    Tries to find a single VM id for a VM matching a given identifier,
    by searching by both name and ip, with option to fail if no matches found
'''
def find_vm_id_from_identifier(identifier, failOnNoMatches=False):
    debug_log("Try to find a unique VMID using identifier {}".format(identifier))
    nameSearch="name={}".format(identifier)
    ipSearch="ip={}".format(identifier)
    debug_log("Search by {}".format(nameSearch))
    vmid = get_vm_id(nameSearch, failOnNoMatches=failOnNoMatches)
    if not vmid:
        debug_log("Search by {}".format(ipSearch))
        vmid = get_vm_id(ipSearch, failOnNoMatches=failOnNoMatches)
    return vmid

'''
    Return the id of VM that matches a given identifier,
    with option to throw exception if no matching VMs found.

    :param identifier: search criteria you would type in the Ovirt search bar.
        YOu want to give something specific like an IP or the name ofyour VM
    :param failOnNoMatches: throw exception if no matching vm found

    :return: String (unique VM id if 1 VM found)

    :throws NoMatchingVmsException if no matches and failOnNoMatches specified

'''
def get_vm_id(identifier, failOnNoMatches=True):

    debug_log("Try to find id of VM using identifier: {}".format(identifier))
    matches = get_matching_vms(identifier)
    if matches:
        if len(matches) > 1:
            raise NotUniqueVmIdentifierException("ERROR: More than one VM matched on identifier {}!  "
                " I can not find a unique VM id for this VM.  "
                "Be more specific".format(identifier))
        return matches[0].id
    if failOnNoMatches:
        raise NoMatchingVmsException("Found no matching VMs for identifier {} " \
            "(If you are sure this identifier should return a result, " \
            " go to ovirt gui, open the 'VM' tab, and try typing {} in " \
            " in the search bar and see if that gives any results)".format(identifier, identifier))

'''
    Get the IP for the VM needed for cluster creation
    Gets the IP on eth0 device

    :param vmid: unique id of VM in Ovirt to get IP of

    :returns: IP address if found
    :throws NoIpException: if no IP found
'''
def get_vm_ip(vmid):

    name = get_vm_name(vmid)
    debug_log("Get IP of VM {}".format(name))

    vm_service = get_vm_service(vmid)
    debug_log("got vm service " + str(vm_service))

    devices = vm_service.reported_devices_service().list()
    for device in devices:
        debug_log("\tFound device: {}".format(device.name))
        if device.name == 'eth0':
            debug_log("is eth0")
            ips = device.ips
            for ip in ips:
                debug_log("\tip " + ip.address)
                # it will return mac address and ip address dont return mac address
                if ip_address(ip.address):
                    return ip.address
                else:
                    debug_log("\t(IP {} is probably a mac address; dont return this one".format(ip.address))

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
        raise RuntimeError("ERROR: Attempting to get vm name; "
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
        debug_log("Could not locate a vm service for vm id {}".format(vmid))
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
        debug_log("VM status: {}".format(vm.status))
    return False

def is_vm_down(vmid):

    vm_service = get_vm_service(vmid)
    vm = vm_service.get()
    if vm.status == types.VmStatus.DOWN:
        return True
    else:
        debug_log("VM status: {}".format(vm.status))
    return False

def wait_for_service_to_come_down(vmid, timeout=SHUTDOWN_TIMEOUT):
    vm_service = get_vm_service(vmid)
    name = get_vm_name(vmid)
    time_remaining = timeout
    sleep_between = 1
    # if waiting is for a vm stop, it should be quick, but for shut downs
    # could take several minutes; just give a generic high est time on the log
    info_log("Wait for service to come down (up to 10 minutes)")
    while time_remaining:
        if is_vm_down(vmid):
            break
        else:
            time.sleep(sleep_between)
            time_remaining -= sleep_between
    if not time_remaining:
        raise TimeoutError("Service never came down on {}, " \
            " after waiting {} seconds".format(name, timeout))

'''
    Checks if VM is up; if so, brings VM safely in to powered off state
    and waits for VM service to display as DOWN in ovirt
'''
def stop_vm(vmid):
    vm_service = get_vm_service(vmid)
    name = get_vm_name(vmid)
    info_log("Power down {}".format(name))
    if not is_vm_down(vmid):
        debug_log("VM is up; Stop VM {}".format(name))
        timeout=60
        while timeout:
            try:
                vm_service.stop()
                break
            except Exception as e:
                timeout-=1
                time.sleep(5)
                debug_log("still getting an exception...." + str(e))
        if not timeout:
            raise TimeoutError("Couldn't stop VM {}".format(name))

    wait_for_service_to_come_down(vmid)

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

    info_log("Remove VM {} from Ovirt".format(identifier))
    vmid = find_vm_id_from_identifier(identifier)
    if not vmid:
        debug_log("No VM found to remove, using identifier : {}".format(identifier))
        raise RuntimeError("ERROR: Could not remove vm of identifier: {}; "
            " VM does not return from search!\n".format(identifier))
    name = get_vm_name(vmid)
    debug_log("Found VM: {}".format(name))

    vm_service = get_vm_service(vmid)

    if releaseIP:
        '''
            Want to release IP before removal.
            Need VM to be up to get IP.
            If VM down bring up so can get IP.
            Then SSH and release the IP
        '''
        info_log("Attempt to release ip before removing {}".format(name))

        if not is_vm_up(vmid):
            debug_log("Bring up {} so can get IP...".format(name))
            bring_up_vm(vmid, waitForIP=True)

        # if vm up, wait until ip displaying in case
        # this is a vm that was just created and we tried to
        # remove right away (in which case IP might not be available yet)
        try:
            assignedIp = wait_for_ip(vmid, IP_ASSIGN_TIMEOUT)
            if assignedIp is None:
                raise Exception("LOGIC ERROR:: wait_for_ip returns without " \
                    " NoIpException, but ip returned is none. Please sync code")
            else:
                info_log("Found IP of VM: {}".format(assignedIp))

                info_log("Release {}/{} from consul".format(name, assignedIp))
                # if puppet wasn't set up, might not work, just catch and go on
                try:
                    run_ssh_cmd(assignedIp, "consul leave")
                except Exception as e:
                    debug_log("consul leave command failed on {}, Reason: {}" \
                        "; ignoring".format(assignedIp, str(e)))

                info_log("Release IP {}".format(assignedIp))
                cmds = [['sudo dhclient -v -r']] # assuming Centos7... @TODO for other cases?
                run_ssh_cmds(assignedIp, cmds)

        except NoIpException:
            '''
                sometimes the IP is not coming up.
                This seems to happen on new VMs that had an issue
                coming up initially.
                So if timed out here,
                just skip getting the IP.  power down and remove like normal
            '''
            warn_log("I could still never get an IP for {}, "
                " even though it shows as up,"
                " will just shut down and remove VM without IP release".format(name))

    # must power down before removal
    stop_vm(vmid)

    info_log("Remove VM {} from Ovirt".format(name))
    timeout = 5
    while timeout:
        try:
            vm_service.remove()
            break
        except Exception as e:
            time.sleep(5)
            if 'is running' in str(e):
                debug_log("vm still running... try again...")
            else:
                raise SystemExit("unexepcted error when trying to remve vm, {}".format(str(e)))
    if not timeout:
        raise TimeoutError("Stopped VM {} and service came down, but could not remove from service".format(name))

    debug_log("Wait for VM to be gone from vms service...")
    timeout = 20
    while timeout:
        try:
            # search by exact name; else will return all vms that grep match the str
            match = get_vm_id("name=" + name)
            # dev check: make sure that function didn't change from throwing exception
            # to returning None
            if not match:
                raise Exception("LOGIC ERROR IN CODE: get_vm_id was throwing Exception on not being able to find"
                    " vm of given identifier, now it's returning None.  Please sync code\n")
            time.sleep(5)
            timeout -= 1
        except:
            debug_log("VM {} no longer exists to vms".format(name))
            break
    if not timeout:
        raise TimeoutError("Stopped VM {} and service came down and removed from service, "
            " but still getting a matching id for this vm!".format(name))

    info_log("Successfully removed VM: {}".format(name))

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

    debug_log("Remove VMs {} in parallel".format(vms))

    procs = []
    sleepBetween = 5
    sleepOffset = 0
    for vm in vms:
        proc = multiprocessing.Process(target=remove_vm, args=(vm,), kwargs={'releaseIP':releaseIP})
        proc.start()
        procs.append(proc)
        time.sleep(sleepBetween)
        sleepOffset += sleepBetween

    # wait for the processes
    process_wait(procs, timeout=500+sleepOffset)

def shutdown_vm(identifier, timeout=SHUTDOWN_TIMEOUT):

    debug_log("Try to shut down VM {} from Ovirt\n".format(identifier))
    # try to get the vm to remove...
    vmid = find_vm_id_from_identifier(identifier)
    if not vmid:
        debug_log("No VM found to shut down, using identifier : {}".format(identifier))
        raise RuntimeError("ERROR: Could not shutdown vm of identifier: {}; "
            " VM does not return from search!\n".format(identifier))
    name = get_vm_name(vmid)

    vm_service = get_vm_service(vmid)

    # shutdown
    if is_vm_up(vmid):
        info_log("Shut down {}".format(name))
        vm_service.shutdown() # send shutdown signal through vms service

    # wait for service to come down outside shutdown block,
    # in case its in the process of shutdown (not up state)
    # when script begins
    wait_for_service_to_come_down(vmid, timeout)

    info_log("Successfully shut down {}".format(name))

'''
    safely power off (shut-down) a list of ovirt vms, in parallel

    :param vms: list of vm 'identifiers'
        Some string which should identify the VM, such as an IP or name
        (same as if you typed the String in the search bar in Ovirt GUI)
        (a String that would give mu ltiple results, won't delete those VMs)
'''
def shutdown_vms(vms):

    debug_log("Shut down VMs {} in parallel".format(vms))

    procs = []
    sleepBetween = 5
    sleepOffset = 0
    for vm in vms:
        proc = multiprocessing.Process(target=shutdown_vm, args=(vm, SHUTDOWN_TIMEOUT))
        proc.start()
        procs.append(proc)
        time.sleep(sleepBetween)
        sleepOffset += sleepBetween

    # wait for the processes
    process_wait(procs, timeout=SHUTDOWN_TIMEOUT+sleepOffset)

'''
    power on existing VMs in to an up state with IP displaying

    :param vms: list of vm 'identifiers'
        Some string which should identify the VM, such as an IP or name
        (same as if you typed the String in the search bar in Ovirt GUI)
        (a String that would give mu ltiple results, won't delete those VMs)
'''
def power_on_vms(vms):

    info_log("Power-on VMs {} (in parallel)".format(", ".join(vms)))

    procs = []
    sleepBetween = 5
    sleepOffset = 0
    for vm in vms:
        vmid = find_vm_id_from_identifier(vm)
        proc = multiprocessing.Process(target=bring_up_vm, args=(vmid,), kwargs={
            'waitForIP':True,
            'power_on_timeout': POWER_ON_TIMEOUT,
            'ip_assign_timeout': IP_ASSIGN_TIMEOUT
        })
        proc.start()
        procs.append(proc)
        time.sleep(sleepBetween)
        sleepOffset += sleepBetween

    # wait for the processes
    process_wait(procs, timeout=POWER_ON_TIMEOUT + IP_ASSIGN_TIMEOUT +sleepOffset)

'''
    reboot nodes in parallel.  Optionally wait for all nodes to come up
'''
def reboot_nodes(vmids, waitForNodesToComeUp=True):

    debug_log("Reboot nodes in parallel")

    procs = []
    sleepBetween = 5
    sleepOffset = 0
    for vmid in vmids:
        ip = get_vm_ip(vmid)
        proc = multiprocessing.Process(target=reboot_node, args=(ip,), kwargs={
            'waitForVmToComeUp': waitForNodesToComeUp,
            'reboot_timeout': REBOOT_TIMEOUT,
            'ip_assign_timeout': IP_ASSIGN_TIMEOUT
        })
        proc.start()
        procs.append(proc)
        sleepOffset+=sleepBetween

    # wait for the processes
    process_wait(procs, timeout=sleepOffset + REBOOT_TIMEOUT + IP_ASSIGN_TIMEOUT)

'''
    Open connection to Ovirt engine.
    (sdk advises to free up this resource when possible)

    :returns: ovirtsdk4:Connection object
'''
def open_connection(user=None):

    info_log("Open connection to Ovirt engine...")

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
            debug_log("Error:", err)

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

    debug_log("close connection to ovirt engine...")
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

    debug_log("Try to provision VM {} on one of the following clusters: {}".format(name, availableClusters))

    for orderedcluster in availableClusters:
        template = get_template(orderedcluster)
        try:
            vmid = create_vm(name, orderedcluster, template, ram, cores)

            if not vmid:
                raise RuntimeError("ERROR: Ovirt seems to have successfully created VM {}, but no id generated\n".format(name))

            # set jenkins password before returning
            # do here instead of during installation in case they don't want to install xcalar
            ip = get_vm_ip(vmid)
            debug_log("Change password for user 'jenkins' on {} ({})".format(name, ip))
            run_ssh_cmd(ip, 'echo "jenkins:{}" | chpasswd'.format(JENKINS_USER_PASS))
            debug_log("Set MariaDB timeout to 30 seconds because it sometimes crashes")
            run_ssh_cmd(ip, 'sed -i \'s:TimeoutSec=300:TimeoutSec=30:\' /usr/lib/systemd/system/mariadb.service')

            # set the hostname now (in case they don't want to install Xcalar)
            setup_hostname(ip, name)
            # setup puppet only after hostname is set

            return True
        #except ResourceException as err:
        except Exception as e:
            debug_log("Exception hit when provisioning VM {}!".format(name))
            if 'available memory is too low' in str(e):
                debug_log("Hit memory error!! :"
                    " Not enough memory on {} to create requested VM"
                    "\nTry to delete it and try on next cluster (if any)...".format(orderedcluster))
                remove_vm(name, releaseIP=False) # set releaseIP as False - else, it's going to try and bring the VM up again to get the IP! and will fail for same reason
            else:
                debug_log("VM provisioning failed for a reason other than memory too low")
                raise e
                #raise Exception("Failed for another reason!: {}".format(str(e)))

    # hit this problem in all of them
    errMsg = "\n\nERROR: There are not enough resources available " \
        " to provision the next VM of {} bytes RAM, {} cores\n" \
        " Tried on clusters: {}".format(ram, cores, availableClusters)
    debug_log(errMsg)
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
def provision_vms(n, basename, ovirtcluster, ram, cores, user=None, tryotherclusters=True):

    if n == 0:
        return None

    if not ram or not cores:
        raise ValueError("ERROR: No value for ram or cores args to provision_vms\n"
            " (perhaps default values changed for the --ram or --cores options?)\n")

    debug_log("Provision {} vms on ovirt node {}\n".format(n, ovirtcluster))

    '''
        get list of cluster we can try to provision the VMs on.
        (if tryotherclusters is True, then can try on other clusters
        other than one specified by ovirtcluster param, in case something
        goes wrong on that cluster)
    '''
    availableClusters = [ovirtcluster]
    if tryotherclusters:
        availableClusters = get_cluster_priority(prioritize=ovirtcluster)
    debug_log("Clusters available to provision the vms on: {}".format(availableClusters))

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
        debug_log("Check first if enough memory available...")
        fullClusList = availableClusters # if fail want to print out the original list of clusters in err message
        availableClusters = enough_memory(n, ram, availableClusters)
        debug_log("Clusters determined we can use: {}".format(str(availableClusters)))
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
    vmnames = generate_vm_names(basename, n)
    sleepBetween = 20
    for nextvmname in vmnames:
        debug_log("Fork new process to create a new VM by name {}".format(nextvmname))
        proc = multiprocessing.Process(target=provision_vm, args=(nextvmname, ram, cores, availableClusters))
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
    for vmname in vmnames:
        ids.append(get_vm_id("name=" + vmname))
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

    :param node:
        (String) ip of node to start Xcalar service on
'''
def start_xcalar(node):

    debug_log("Start Xcalar service on node {}\n".format(node))
    cmds = [['service xcalar start', 600]]
    run_ssh_cmds(node, cmds)

'''
    Bring down Xcalar service on node

    :paran node: (String) ip of node to stop xcalar service on
'''
def stop_xcalar(node):

    debug_log("Stop Xcalar service on node {}\n".format(node))
    cmds = [['service xcalar stop', 120]]
    run_ssh_cmds(node, cmds)

'''
    Bring up xcalar service on a node and setup admin account

    :param node: (String) ip of node to setup admin account on
'''
def setup_admin_account(node):

    info_log("Setup admin account on {}".format(node))

    # scp in shell script that sets up default admin account; it looks for
    # defaultAdmin.json at vm's root
    scp_file(node, SCRIPT_DIR + '/../docker/xpe/staticfiles/defaultAdmin.json', '/')
    scp_file(node, SCRIPT_DIR + '/' + ADMIN_HELPER_SH_SCRIPT, TMPDIR_VM)
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

    vmname = get_vm_name(get_vm_id("ip=" + ip))

    info_log("Install Xcalar on {}, using RPM installer: {} (5-10 minutes)".format(vmname, installer))

    '''
        There is an end-to-end shell script whicho will
        do install, generate template file, put lic files in right dir, etc.
        create a tmpdir and copy in that helper shell script,
        along with dependencies.
    '''

    # create tmp dir to hold the files
    run_ssh_cmd(ip, 'mkdir -p {}'.format(TMPDIR_VM))

    # copy in installer shell script and files it depends on
    fileslist = [[SCRIPT_DIR + '/' + INSTALLER_SH_SCRIPT, TMPDIR_VM],
        [SCRIPT_DIR + '/' + TEMPLATE_HELPER_SH_SCRIPT, TMPDIR_VM], # installer script will call this template helper script
        # rename lic file to std name in case they supplied a file with a diff name, because e2e script will call by st name
        [licfilepath, TMPDIR_VM + '/' + LICFILENAME]]
    for filedata in fileslist:
        scp_file(ip, filedata[0], filedata[1])

    # install using bld requested
    run_sh_script(ip, TMPDIR_VM + '/' + INSTALLER_SH_SCRIPT, args=[installer, ip], timeout=2000)

    # start xcalar
    start_xcalar(ip)

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

    debug_log("installer: " + str(installer))
    debug_log("Setup xcalar on node set and cluster {}".format(createcluster))

    procs = []
    ips = []

    sleepBetween = 15
    for vmid in vmids:
        # get ip
        ip = get_vm_ip(vmid)
        name = get_vm_name(vmid)
        ips.append(ip)
        debug_log("Start new process to setup xcalar on {}, {}".format(name, ip))
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
        power up all the nodes in parallel and set up admin account
        doing here instead of in initial setup, because for cluster nodes,
        cluster needs to be created before admin account can get setup in shared storage
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
        raise ValueError("ERROR: Empty list of node ips passed to create_cluster;"
            " No nodes  make cluster on!\n")

    '''
        Create a shared storage space for the nodes
        on netstore, using cluster name
    '''
    sharedRemoteStoragePath = 'ovirtgen/' + clustername
    create_cluster_dir(sharedRemoteStoragePath)

    # for each node, generate config file with the nodelist
    # and then bring up the xcalar service
    info_log("Create cluster using nodes : {}".format(nodeips))
    procs = []
    sleepBetween = 15
    for ip in nodeips:
        debug_log("\tFork cluster config for {}\n".format(ip))
        '''
        Note: The order of the ips in nodeips list is important!!
        Will be node 0 (root cluster node), node1, etc., in order of list
        '''
        proc = multiprocessing.Process(target=configure_cluster_node, args=(ip, nodeips, NETSTORE_IP, sharedRemoteStoragePath))
        procs.append(proc)
        proc.start()
        time.sleep(sleepBetween)

    # wait for all the proceses to complte
    process_wait(procs, timeout=600+sleepBetween*len(nodeips))

'''
    Create a directory on netstore intended to be shared
    storage by all nodes in the cluster.

    :param remotePath: (String)
        path on the remoteIP to use as the shared cluster storage

    @TODO:
        Handle taking a general IP (and credentials?) in case ever want
        to create the shared storage somewhere other than netstore
'''
def create_cluster_dir(remotePath):

    # -m 0777 needed because xcalar needs to be owner but can't chown after rootsquash
    dirPath = '/netstore/' + remotePath
    info_log("Create shared cluster storage on netstore: {}".format(dirPath))
    cmds = ['mkdir -p -m 0777 ' + dirPath]
    for cmd in cmds:
        run_system_cmd(cmd)

'''
    Configure a node to be part of a cluster
    by generating its default.cfg with a nodelist,
    and bringing up the node

    :param node: (String)
        ip of node
    :param clusternodes: (list of Strings)
        list of IPs of all the nodes in the cluster
            ORDER OF THIS LIST IS IMPORTANT.
            clusternodes[0] : root node (node 0)
            clusternodes[1] : node1
            ... etc
    :pararm remoteIP: (String)
        IP of the machine with the shared cluster storage
    :param remoteClusterStoragePath: (String)
        remote path remoteIP for the shared cluster storage for the nodes

'''
def configure_cluster_node(node, clusternodes, remoteIP, remoteClusterStoragePath):

    debug_log("Configure node {} as part of cluster nodes: {}\n".format(node, clusternodes))

    debug_log("get node's local path to the shared cluster storage directory on netstore, {}".format(remoteClusterStoragePath))
    local_cluster_storage_dir = setup_cluster_storage(node, remoteIP, remoteClusterStoragePath)

    debug_log("generate cluster template file...")
    generate_cluster_template_file(node, clusternodes, local_cluster_storage_dir)

'''
    Setup access to remote cluster storage on to the node

    :paran node: (String)
        IP of the node to set shared storage on
    :param remoteIP: (String)
        IP of the machine with the shared storage
        (right now always using netstore - adding this in so it will be
        easy to change things)
    :param remotePath: (String) path on netstore to shared storage

    :returns: (String)
        local path on the node, to the shared cluster storage
'''
def setup_cluster_storage(node, remoteIP, remotePath):

    debug_log("Determine local path VM {} should use for xcalar home "
        " (Constants.XcalarRootCompletePath var in  /etc/xcalar/default.cfg".format(node))

    # i think this will make the puppet change (which include automounting netstore)
    # take effect?
    run_ssh_cmd(node, "systemctl restart autofs")

    '''
        Check if netstore already mounted on the VM, with the remote path available
        (puppet should set up automount of netstore on all the VMs.)
        Check at an expected locaton; only if it is not already avaialble, mount netstore
        (Check several times, because bind mount issues)
    '''
    tries = 50
    netstoreMountDir = "/netstore"
    possiblePath = netstoreMountDir + "/" + remotePath
    while tries:
        if path_exists_on_node(node, possiblePath):
            info_log("Shared cluster storage already accessible to node {}, at {}".format(node, possiblePath))
            return possiblePath
        time.sleep(5)
        tries -= 1

    # if here, was not able to access through the possible path, even accounting
    # for automount lags.  Mount netstore directly
    # (the method called will return the local dir to the remote shared storage that results after successful mount)
    return mount_shared_cluster_storage(node, remoteIP, remotePath, netstoreMountDir)

'''
    Mount a directory on Netstore provisioned for shared cluster storage,
    on a cluster node.

    :param node: (String)
        IP of node to mount the storage space on
    :param remoteIP: (String)
        IP of the machine with the shared storage space
    :param remotePath: (String)
        Path on on remoteIP to shared storage space
    :param mountDir: (String)
        local directory to mount remoteIP to
        (NOT local dir to remotePath)

    :returns (String)
        local path on node, to the shared cluster storage (remoteIP's remotePath)

'''
def mount_shared_cluster_storage(node, remoteIP, remotePath, mountDir):

    info_log("Mount netstore directory {} to {} on {} as shared cluster storage\n"
        .format(remotePath, mountDir, node))

    '''
        add nfs mount instructions for netstore, in to fstab,
        then mount from that
        (having the instructions in fstab will mount again if node reboots)
    '''
    fsTabEntry = "{}: {} {} nfs rsize=8192,wsize=8192,timeo=14,intr".format(remoteIP, remotePath, mountDir)
    run_ssh_cmd(node, "echo '{}' >> /etc/fstab".format(fsTabEntry))
    # now that it's in fstab, can mount via the specified mount point
    # (the mount point must exist first)
    run_ssh_cmd(node, "mkdir -p {}; mount {}".format(mountDir, mountDir), timeout=400)

    '''
        make sure the shared cluster storage
        now accessible on the node
    '''
    sharedStorageLocalDir = mountDir + "/" + remotePath
    if not path_exists_on_node(node, sharedStorageLocalDir):
        raise RuntimeError("Shared cluster storage dir on netstore, {}, not accessible locally on node {}, even after nfs mount".format(remotePath, node))

    return sharedStorageLocalDir

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

    debug_log("Generate /etc/xcalar/default.cfg file for node {}, set with cluster nodes {}\n".format(node, clusternodes))

    # there's a shell script for that
    nodeliststr = ' '.join(clusternodes)
    #scp_file(node, TEMPLATE_HELPER_SH_SCRIPT, TMPDIR_VM) # the e2e installer needs this script too so if it's not present I want this to fail
    # so don't copy it in
    run_sh_script(node, TMPDIR_VM + '/' + TEMPLATE_HELPER_SH_SCRIPT, args=[xcalarRoot, nodeliststr])

'''
    Check if a path exists on a remote node

    :param node: (String) ip of node to check path on
    :param path: (String) path to check on the node

    :returns True (path exists) or False (path does not exist)
'''
def path_exists_on_node(node, path):

    try:
        run_ssh_cmd(node, 'ls ' + path, timeout=10)
        return True
    except Exception as e:
        debug_log("Can't ls to {} on {}: {}".format(path, node, e))
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
    devClusters = ['ovirt-node-1-cluster', 'einstein-cluster2' ]
    qaClusters = ['node3-cluster', 'node2-cluster', 'node1-cluster']
    clusterPriority = devClusters
    validClusters = []
    mapping = get_template_mapping() # get the official template mapping
    if prioritize:
        if prioritize in OVIRT_TEMPLATE_MAPPING:
            validClusters.append(prioritize)
        else:
            raise RuntimeError("ERROR: Trying to prioritize {}, but there "
                " is no template for this Cluster. (have you added an entry in "
                " OVIRT_TEMPLATE_MAPPING for it?)\n".format(prioritize))
    for orderedcluster in clusterPriority:
        if orderedcluster != prioritize and orderedcluster in OVIRT_TEMPLATE_MAPPING:
            validClusters.append(orderedcluster)
    return validClusters

'''
    Return name of template and cluster template is on,
    depending on what args requestesd (RAM, num cores, etc.)
'''
def get_template(ovirtcluster):

    '''
    @TODO:
        Select the template based on their preferences
        of RAM, etc.
        For now, just base on the ovirt cluster specified
    '''

    # make so the value is a hash with keys for RAM, cores, etc.
    #and appropriate template for now just one std template each
    # check that the node arg a valid option
    if ovirtcluster in OVIRT_TEMPLATE_MAPPING.keys():
        ## todo - there should be templates for all the possible ram/cores/etc configs
        return OVIRT_TEMPLATE_MAPPING[ovirtcluster]
    else:
        raise AttributeError("ERROR: No template found for ovirt node {}."
            "\nValid nodes with templates: {}\n".format(ovirtcluster, ", ".join(OVIRT_TEMPLATE_MAPPING.keys())))

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

    debug_log("SCP: Copy file {} from host, to {}:{}".format(localfilepath, node, remotefilepath))

    # adding -i option back in for new employees that dont have vault set up
    # todo : remove the ovirt public key from authorized_keys of generated vms
    cmd = 'scp -i ' + keyfile + ' -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no ' + localfilepath + ' root@' + node + ':' + remotefilepath
    run_system_cmd(cmd)

def run_ssh_cmds(host, cmds):

    debug_log("Send cmds to {} via SSH.  cmd list: {}".format(host, str(cmds)))

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
        run_ssh_cmd(host, cmd[0], **extraops)

'''
    tryOtherUsers: list of other users to try ssh'ing as, in that order, if 'user' fails
'''
def run_ssh_cmd(host, command, port=22, user=DEFAULT_SSH_USER, bufsize=-1, keyfile=OVIRT_KEYFILE_DEST, timeout=120, valid_exit_codes=[0], pkey=None, tryOtherUsers=["root", "jenkins"]):

    ## users to try ssh'ing as;
    ## prioritize main 'user' arg, maintain order of tryOtherUsers
    try_users = tryOtherUsers
    try:
        try_users.remove(user) # if 'user' in list remove so can prioritize at front
    except:
        pass
    try_users.insert(0, user)

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    connected_user = None # user able to make a connection as
    last_exception = None # if can't connect any users, will raise most rec. exception
    for next_user in try_users:
        debug_log("Connection attempt: ssh {}@{}".format(next_user, host))
        try:
            client.connect(hostname=host, port=port, username=next_user, key_filename=keyfile)#, key_filename=key_filename, banner_timeout=100)
            connected_user = next_user
            debug_log("connected to ... {} as user {}".format(host, connected_user))
            break
        except Exception as e:
            last_exception = e
            # if keyfile isn't in authorized_keys of the user you're trying to
            # ssh as, paramiko will throw a paramiko.ssh_exception.SSHException
            # with "not a valid OPENSSH private key"
            # just catch any err in case change on other paramiko versions
            debug_log("Error connecting to {}: {}; " \
                " try to attempt other user if available...".format(next_user, str(e)))
    if not connected_user:
        info_log("Could not establish ssh connection to {} with " \
            "any available users: {}; " \
            "Throwing most recent exception".format(host, ", ".join(try_users)))
        raise last_exception

    chan = client.get_transport().open_session()
    chan.settimeout(timeout)
    debug_log("[{}@{}  ~]# {}".format(connected_user, host, command))
    chan.exec_command(command)
    stdout = chan.makefile('r', bufsize) # opens stdout stream
    stderr = chan.makefile_stderr('rb', bufsize) # opens stderr stream
    stdout_text = stdout.read()
    stderr_text = stderr.read()
    stdout_formatted_text = stdout_text.decode("utf-8")
    stderr_formatted_text = stderr_text.decode("utf-8")
    debug_log("stdout:\n\t{}".format(stdout_formatted_text))
    debug_log("stderr:\n\t{}".format(stderr_formatted_text))
    status = int(chan.recv_exit_status())
    debug_log("status: {}".format(status))
    if status not in valid_exit_codes:
        summary = "Encountered invalid exit status {}. Valid codes: {}".format(status, ', '.join(str(x) for x in valid_exit_codes))
        raise ShellError(command, host, status, stdout_formatted_text, stderr_formatted_text, summary)
    client.close()
    return status, stdout_formatted_text, stderr_formatted_text

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
        debug_log(" $ {}".format(cmd))
        cmdout = subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True)
    except subprocess.CalledProcessError as e:
        debug_log("Stderr: {}\n\nGot error when running sys command {}:\n{}".format(str(e.stderr), cmd, str(e.output))) # str on output in case None
        sys.exit(e.returncode)

    '''
    debug_log("~:$ {}".format(cmd))
    os.system(cmd)
    '''

'''
    Run a shell script on a node

    :param node:
        (String) IP of node to run shell script on
    :param path:
        (String) filepath (on node) of shell script to run
    :param args:
        (list) list of Strings as positional args to supply to shell script
    :redirect:
        if True will redirct shell output on node to OVIRT_SHELL_LOGS_DIR
        (if dir does not exist on node will create it)
    :debug:
        if True will run bash with -x option

'''
def run_sh_script(node, path, args=[], timeout=120, redirect=True, debug=True):

    debug_log("Run shell script {} on node {}...\n".format(path, node))

    bashCall = '/bin/bash'
    if debug:
        bashCall += ' -x'
    shellCmd = bashCall + ' ' + path + ' ' + ' '.join(args)
    cmds = []
    outputFile = None
    if redirect:
        cmds.append(['mkdir -p ' + OVIRT_SHELL_LOGS_DIR])
        outputFile = OVIRT_SHELL_LOGS_DIR + "/" + os.path.basename(path) + "_log"
        shellCmd += ' &> ' + outputFile
    cmds.append([shellCmd, timeout])
    try:
        run_ssh_cmds(node, cmds)
    except ShellError as e:
        errInfo = "\nHit error running shell script {} on {}.  ERROR: {}".format(path, node, e.summary)
        if outputFile: # no stderr to print to them it was all redirected
            errInfo += "\nLogfile for this shell script @ {} on {}\n".format(outputFile, node)
        else:
            errInfo += "\nStderr:\n\t{}".format(e.stderr)
        raise_from(Exception(errInfo), e)

'''
    Given a list of multiprocessing:Process objects,
    wait until all the Process objects have completed.

    :procs: list of multiprocessing.Process objects representing the processes to monitor
    :timeout: how long (seconds) to wait for ALL processees
        in procs to complete, before timing out.  If not supplied, will not
        timeout and will keep going indefinetely
    :valid_exit_codes: valid exit codes to come back from the process; list of ints
'''
def process_wait(procs, timeout=None, valid_exit_codes=[0]):

    numProcsStart = len(procs)

    # wait for all the processes to complete
    time_remaining = timeout
    secs_sleep_between = 5
    while procs:
        debug_log("\t\t:: Check processes... ({} processes remain)".format(len(procs)))
        for i, proc in enumerate(procs):
            if proc.is_alive():
                time.sleep(secs_sleep_between)
                if timeout:
                    time_remaining -= secs_sleep_between
            else:
                exitcode = proc.exitcode
                if exitcode not in valid_exit_codes:
                    raise RuntimeError("Encountered invalid exit code, {} in " \
                        "a forked child process.  " \
                        "Valid exit codes for these processes: " \
                        "{}".format(exitcode, ', '.join(str(x) for x in valid_exit_codes)))
                del procs[i]
                break

        if timeout and not time_remaining:
            raise TimeoutError("Timed out waiting for processes to complete! " \
                "{}/{} processes remain!".format(len(procs), numProcsStart))

    debug_log("All processes completed with valid exit codes")

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
    Given an IP of a machine with Xcalar,
    get protocol and port used by Caddy from the Caddyfile

    @returns list:
        [ https|http, <port>]
'''
def get_caddy_config_debug_log(ip):

    caddyInfo = []

    caddyfilePath = "/etc/xcalar/Caddyfile"
    # should be a main line in Caddyfile of format http|https://0.0.0.0<:port>
    grepCmd = "grep -oP '(http|https)://0\.0\.0\.0:(\d+)' " + caddyfilePath

    # first make sure that line exists (helpful to check for this line not being there
    # in case the next grep commands return no output)
    status, stdout, stderr = run_ssh_cmd(ip, grepCmd)
    if not stdout:
        raise ValueError("Could not get main proxy line from Caddyfile {} on {}" \
            "\n(Used grep cmd: {} - Does it need to be updated?)".format(caddyfilePath, ip, grepCmd))

    # determine if http or https by piping in to another grep
    # (doing 2 greps so don't catch http as subset of https)
    status, stdout, stderr = run_ssh_cmd(ip, grepCmd + " | grep -oP '(http:|https:)' | grep -oP '(\w+)'")
    if not stdout:
        raise ValueError("Couldn't determine http vs. https from Caddyfile")
    protocol = stdout.strip()

    # now get the port
    status, stdout, stderr = run_ssh_cmd(ip, grepCmd + " | grep -oP ':(\d+)' | grep -oP '(\d+)'")
    if not stdout:
        raise ValueError("Couldn't determine port from Caddyfile")
    port = stdout.strip()

    caddyInfo = [protocol, port]
    return caddyInfo

'''
    Given an IP of a node with xcalar installed,
    display a correct access URL for that machine based on its Caddy configuration
'''
def get_access_url(ip):
    caddyInfo = get_caddy_config_debug_log(ip)
    caddyProtocol = caddyInfo[0]
    caddyPort = caddyInfo[1]
    hostname = get_hostname(ip)
    # if port is default, don't display it
    if (caddyPort == "443" and caddyProtocol == "https") or (caddyPort == "80" and caddyProtocol == "http"):
        return "{}://{}".format(caddyProtocol, hostname)
    return "{}://{}:{}".format(caddyProtocol, hostname, caddyPort)

'''
    Returns a summary string with debugrmation about vms
'''
def summary_str_created_vms(vmids, ram, cores, ovirt_cluster, installer=None, clustername=None):

    notes = []
    created_vms_summary = "\n\n=====================================================\n" \
        "------------ Your Ovirt VMs are ready!!! ------------\n" \
        "|\n" \
        "|\n| " + str(len(vmids)) + " VMs were created.\n" \
        "|\n| The VMs have the following specs:\n" \
        "|\tRAM (GB)     : " + str(ram) + "\n" \
        "|\t#  Cores     : " + str(cores) + "\n"
    if installer:
        created_vms_summary = created_vms_summary + "|\tInstaller    : " + str(installer) + "\n"
        #created_vms_summary = created_vms_summary + "\n|\tOvirt cluster: {}".format(ovirt_cluster) # it might have gone to another cluster. need to check through sdk

    # get the ips from the ids
    vmips = [get_vm_ip(vmid) for vmid in vmids]

    vm_ssh_creds = "|\tssh creds: jenkins/" + JENKINS_USER_PASS

    created_vms_summary = created_vms_summary + "|\n=====================THE VMS=========================\n|\n"
    for i, vmid in enumerate(vmids):
        vmip = get_vm_ip(vmid)
        vmhostname = get_hostname(vmip)
        # if multiple vms put a separator line between them
        if len(vmids) > 1 and i > 0:
            created_vms_summary = created_vms_summary + "|\n|      --------------------------------------" + "\n"
        created_vms_summary = created_vms_summary + "|\tHostname: " + vmhostname + "\n" + vm_ssh_creds + "\n"
        if installer:
            accessUrl = get_access_url(vmip)
            created_vms_summary = created_vms_summary + "|\n|\tAccess URL: " + accessUrl + "\n" \
                "|\tUsername (login page): " + LOGIN_UNAME + "\n" \
                "|\tPassword (login page): " + LOGIN_PWORD + "\n"

    if installer:
        created_vms_summary = created_vms_summary + "|\n| License key * (see note): \n|\n" + LICENSE_KEY + "\n"
        notes.append("LICENSE KEY: This is a dev key and will not work on RC builds")

    clussumm = ""
    if clustername:
        clusternodedata = validate_cluster(vmips)
        debug_log("node data: " + str(clusternodedata))

        # get node 0 for access URL
        if not '0' in clusternodedata:
            raise ValueError("No '0' entry in cluster node data: {}".format(clusternodedata))
        node0ip = clusternodedata['0']
        accessUrl = get_access_url(node0ip)

        clussumm = "\n|\n=================== CLUSTER INFO ====================\n" \
            "|\n| Your VMs have been formed in to a cluster.\n" \
            "|\n| Cluster name: " + clustername  + "\n" \
            "| Access URL:\n|\t" + accessUrl + "\n" \
            "|\tLogin page Credentials: " + LOGIN_UNAME + " \ " + LOGIN_PWORD + "\n" \
            "|\n ------------------------------------------\n"
        for nodenum in clusternodedata.keys():
            # get the name of the VM
            ip = clusternodedata[nodenum]
            vmhostname = get_hostname(ip)
            clussumm = clussumm + "|\n| Cluster Node" + nodenum + " is vm " + vmhostname + "]\n"
        clussumm = clussumm + "|\n ------------------------------------------" + "\n"
    created_vms_summary = created_vms_summary + clussumm

    if notes:
        created_vms_summary = created_vms_summary + "|\n=====================================================\n" \
            "|\n|                  Notes              \n"
        for note in notes:
            created_vms_summary = created_vms_summary + "|\n| * {}\n".format(note)

    created_vms_summary = created_vms_summary + "|\n====================================================="

    return created_vms_summary

'''
    display a summary of work done
    (putting in own function right now so can deal with where to direct output... in here only
    once logging set up ill change
'''
def get_summary_string(vmids, ram, cores, ovirt_cluster, installer=None, clustername=None):

    summary_str = ""

    # vms were created
    if vmids:
        summary_str = summary_str + summary_str_created_vms(vmids, ram, cores, ovirt_cluster, installer=installer, clustername=clustername)

    # print debug on delete, shutdown, or powered on VMs with this job
    if args.delete:
        summary_str = summary_str + "\n\n====================================="\
                        "\n|\n|  The following VMs were deleted:\n|"
        for deletedVm in args.delete.split(','):
                    summary_str = summary_str + "\n|\t{}".format(deletedVm)
        summary_str = summary_str + "\n|\n================================="

    if args.shutdown:
        summary_str = summary_str + "\n\n====================================="\
                        "\n|\n|  The following VMs have been shut down:\n|"
        for shutDownVm in args.shutdown.split(','):
                    summary_str = summary_str + "\n|\t{}".format(shutDownVm)
        summary_str = summary_str + "\n|\n================================="

    if args.poweron:
        summary_str = summary_str + "\n\n====================================="\
                        "\n|\n|  The following VMs are powered on:\n|"
        for poweredOnVm in args.poweron.split(','):
                    summary_str = summary_str + "\n|\t{}".format(poweredOnVm)
        summary_str = summary_str + "\n|\n================================="

    return summary_str

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

    debug_log("Check if cluster is up from perspective of node {}".format(ip))

    cmd = '/opt/xcalar/bin/xccli -c version'
    status, stdout, stderr = run_ssh_cmd(ip, cmd)
    debug_log("OUTPUT:\n\n" + stdout)
    if 'error' in stdout.lower():
        debug_log("Cluster is not up from perspective of node with ip: {}."
            "\nOutput of {} "
            "(was used to determine cluster status):\n{}".format(ip, cmd, stdout))
        return False

    # right now determining cluster is up if not finding error
    debug_log("Cluster is up from perspective of node with ip: {}"
        "\n(Used stdout of {} to determine; did not find error string so determined up."
        "\nstdout: {}".format(ip, cmd, stdout))
    return True

'''
    Log in to each cluster node,
    and make sure its node0, node1, etc. is showing
    in order specified
'''
def validate_cluster(clusterips):

    debug_log("validate cluster nodes {} ".format(clusterips))

    currip = None
    curriplist = None
    for i, ip in enumerate(clusterips):

        # check if cluster showing up through this node
        if not is_cluster_up(ip):
            raise RuntimeError("Cluster is NOT up from the perspective of node {}".format(ip))

        # get list of ips and check against last node's list
        nextiplist = extract_cluster_node_ips(ip)
        debug_log("Node ip list for {}:\n{}".format(ip, nextiplist))
        if i > 0:
            # make sure it matches against last
            for nodeidentifier in nextiplist.keys():
                # make sure same nodenum with ip in last list
                if curriplist[nodeidentifier] != nextiplist[nodeidentifier]:
                    raise ValueError("Node lists among two nodes in the cluster do not match!\n"
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
    debug_log("Extract cluster node data from {}  file on {}".format(configfilepath, ip))

    status, stdout, stderr = run_ssh_cmd(ip, 'cat ' + configfilepath)

    nodeips = {}

    # get num nodes in the cluster
    numnodes = None
    nodenumreg = re.compile('.*Node\.NumNodes=(\d+).*', re.DOTALL)
    matchres = nodenumreg.match(stdout)
    if matchres:
        debug_log("found match")
        numnodes = int(matchres.groups()[0])
    else:
        raise AttributeError("\nFound no entry for number of nodes in {} on {}\n".format(configfilepath, ip))

    # parse all the node data
    nodeipdata = re.compile('.*Node\.(\d+)\.IpAddr=([\d\.]+).*')
    for line in stdout.split('\n'):
        debug_log("Next line: {}".format(line))
        matchres = nodeipdata.match(line)
        if matchres:
            debug_log("Found match of node data on line : {}".format(line))
            # get the node # and ip
            captures = matchres.groups()
            nodenum = captures[0]
            nodeip = captures[1]

            if nodenum in nodeips:
                raise AttributeError("Node{} already registered to ip {}".format(nodenum, nodeip))
            debug_log("add entry {}:{}".format(nodenum, nodeip))
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
    destDir = os.path.dirname(OVIRT_KEYFILE_DEST)
    cmds = ['mkdir -p ' + destDir,
            'cp ' + SCRIPT_DIR + '/' + OVIRT_KEYFILE_SRC + ' ' + OVIRT_KEYFILE_DEST,
            'chmod 400 ' + OVIRT_KEYFILE_DEST]

    if os.path.exists(OVIRT_KEYFILE_DEST):
        debug_log("Ovirt key file {} already exists, remove".format(OVIRT_KEYFILE_DEST))
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
            # validate the name they supplied is all lower case and contains no illegal chars (will be setting hostname of the VMs to the VM name)
            if any(filter(str.isupper, args.vmbasename)) or any(illegal_char in args.vmbasename for illegal_char in ILLEGAL_VMNAME_CHARS):
                raise ValueError("\n\nERROR: --vmbasename value must be all "
                    "lower case letters, and may not contain any of "
                    "the following chars: {}\n".format(" ".join(ILLEGAL_VMNAME_CHARS)))

            '''
                if the basename begins with one of Ovirt's search refining keywords
                (a string you can type in the GUI's search field to refine a search, ex. 'cluster', 'host')
                then the vms_service.list api will not work.
                this leads to confusing results which are not immediately obvious what's going on
            '''
            for ovirtSearchFilter in PROTECTED_KEYWORDS:
                if args.vmbasename.startswith(ovirtSearchFilter):
                    raise ValueError("\n\nERROR: --vmbasename can not begin with any of the values: {} (These are protected keywords in Ovirt)".format(PROTECTED_KEYWORDS))

        if args.ovirtcluster:
            # make sure they supplied a valid cluster with a template
            if args.ovirtcluster not in OVIRT_TEMPLATE_MAPPING:
                raise ValueError("\n\nERROR: --ovirtcluster={}.  No template found for {}.\n"
                    "Valid clusters that can be selected: {}\n".format(args.ovirtcluster, args.ovirtcluster, ", ".join(OVIRT_TEMPLATE_MAPPING.keys())))

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
            debug_log("Make sure license keys are present....")

            scriptcwd = os.path.dirname(os.path.realpath(__file__))
            if not licfilepath:
                licfilepath = SCRIPT_DIR + '/' + LICFILENAME
                debug_log("\tYou did not supply --licfile option... will look in script's cwd for Xcalar license file...")
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
        if not args.delete and not args.shutdown and not args.poweron:
            raise AttributeError("\n\nERROR: Please re-run this script with arg --count=<number of vms you want>\n")

    return int(args.ram), int(args.cores), args.ovirtcluster, licfilepath, installer, basename

'''
    validates lists of vms for param validation.
    :listOptionMapping: hash where key is name of the cmd arg for that list
        (so can include it in error msg), and value is the list to validate for that arg
'''
def validateVmLists(listOptionMapping):
    errMsg = ""
    for cmdArgName in listOptionMapping.keys():
        # validate list of VMs for that cmd arg
        invalidIdentifiers = []
        for vmIdentifier in listOptionMapping[cmdArgName]:
            if not find_vm_id_from_identifier(vmIdentifier):
                invalidIdentifiers.append(vmIdentifier)
        if invalidIdentifiers:
            errMsg = errMsg + "\nError on {}: " \
                "invalid VMs specified: {}".format(cmdArgName, ", ".join(invalidIdentifiers))
    if errMsg:
        valid_vms = get_all_vms()
        errMsg = "{}\n{}\n\nPlease see list of valid vms above\n".format("\n\t".join(valid_vms), errMsg)
        raise ValueError(errMsg)

'''
    Check if a String is in format of ip address
    Does not ping or make sure valid, just checks format

    :param string: String to check if its an ip address

    :returns: True if ip address, False otherwise
'''
def ip_address(string):

    try:
        socket.inet_aton(string)
        debug_log("{} is in valid IP address format".format(string))
        return True
    except Exception as e:
        debug_log("{} not showing as a valid IP address".format(string))
        return False

'''
    some user-supplied arguments allow multiple values.
    This function splits such values in to a list of values.  Error on dupes.
    (Gets own function so if delimeter changes, only need to change here)

    :paramName: String to display in Error output in dupe case,
         indicating which param is having an issue
    :paramValue: the param the user supplied

'''
def getMultiParamValues(paramName, paramValue, errorOnDupes=True):
    splitList = paramValue.split(',')
    values = {}
    dupes = []
    for arg in splitList:
        if arg in values.keys():
            dupes.append(arg)
        else:
            values[arg] = ''
    if dupes and errorOnDupes:
        raise ValueError("\n\nERROR: Duplicate values were supplied " \
            "to {}: {}\n".format(paramName, ", ".join(dupes)))
    return values.keys()


if __name__ == "__main__":

    '''
        Parse and validation cmd arguments
    '''

    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--count", type=int, default=0,
        help="Number of VMs you'd like to create")
    parser.add_argument("--vmbasename", type=str,
        help="Basename to use for naming the new VM(s) (If creating a single VM, will name VMBASENAME, if multiple, will name them VMBASENAME-vm0, VMBASENAME-vm1, .., VMBASENAME-vm(n-1) )")
    parser.add_argument("--cores", type=int, default=DEFAULT_CORES,
        help="Number of cores per VM. (Defaults to {} cores)".format(DEFAULT_CORES))
    parser.add_argument("--ram", type=int, default=DEFAULT_RAM,
        help="RAM on VM(s) (in GB).  (Defaults to {})".format(DEFAULT_RAM))
    parser.add_argument("--nocluster", action='store_true',
        help="Do not create a Xcalar cluster of the new VMs.")
    parser.add_argument("--installer", type=str, #default='builds/Release/xcalar-latest-installer-prod',
        help="URL to RPM installer to use for installing Xcalar on your VMs.  (Should be an RPM installer you can curl, example: http://netstore/<netstore's path to the installer>). \nIf not supplied, will use RPM installer for latest BuildTrunk prod build.)")
    parser.add_argument("--noinstaller", action="store_true", default=False,
        help="Don't install Xcalar on provisioned VM(s)")
    parser.add_argument("--ovirtcluster", type=str, default=DEFAULT_OVIRT_CLUSTER,
        help="Which ovirt cluster to create the VM(s) on.  (Defaults to {})".format(DEFAULT_OVIRT_CLUSTER))
    parser.add_argument("--tryotherclusters", action="store_true", default=False,
        help="If supplied, then if unable to create the VM on the given Ovirt cluster, will try other clusters on Ovirt before giving up")
    parser.add_argument("--licfile", type=str,
        help="Path to a XcalarLic.key file on your local machine (If not supplied, will look for it in cwd)")
    parser.add_argument("--puppet_role", type=str, default=DEFAULT_PUPPET_ROLE,
        help="Role the VM(s) should have (Defaults to {})".format(DEFAULT_PUPPET_ROLE))
    parser.add_argument("--puppet_cluster", type=str,
        help="Puppet cluster to enable")
    parser.add_argument("--delete", type=str,
        help="Single VM or comma separated String of VMs you want to remove from Ovirt (could be, IP, VM name, etc).")
    parser.add_argument("--shutdown", type=str,
        help="Single VM or comma separated String of VMs you want to shut down (could be, IP, VM name, etc).  This will help free up resources while your VM is not in use.")
    parser.add_argument("--poweron", type=str,
        help="Single VM or comma separated String of VMs to power on")
    parser.add_argument("--user", type=str,
        help="Your SSO username (no '@xcalar.com')")
    parser.add_argument("-f", "--force", action="store_true", default=False,
        help="Force certain operations such as provisioning, delete, when script would fail normally")

    args = parser.parse_args()

    ram, cores, ovirtcluster, licfilepath, installer, basename = validateparams(args)
    FORCE = args.force

    # script setup
    setup()

    #open connection to Ovirt server
    CONN = open_connection(user=args.user)

    # validation that requires a connection to the Ovirt engine (validating VMs)
    #doing all validation before calling any of the operations so can fail out early
    deleteVms = []
    shutdownVms = []
    poweronVms = []
    if args.delete:
        deleteVms = getMultiParamValues("--delete", args.delete) # errs on dupes
    if args.shutdown:
        shutdownVms = getMultiParamValues("--shutdown", args.shutdown)
    if args.poweron:
        poweronVms = getMultiParamValues("--poweron", args.poweron)
    # validate all the VMs in these lists are valid
    # validating in one go because want to display list of valid vms
    # in err msg; don't want to repeat that list for each arg that could have invalid entries
    validateVmLists({"--delete": deleteVms, "--shutdown": shutdownVms, "--poweron": poweronVms})

    ## DO REQUESTED OPERATIONS ##

    '''
        remove vms first if requested, to free up resources
    '''
    if args.delete and deleteVms: # to be on the safe side check both?
        remove_vms(deleteVms)

    '''
        shut down VMs if requsted, to free up resources
    '''
    if args.shutdown and shutdownVms:
        shutdown_vms(shutdownVms)

    '''
        power up existing VMs if requested before creating new ones
    '''
    if args.poweron and poweronVms:
        power_on_vms(poweronVms)

    ''''
        main driver
    '''

    #  spin up number of vms requested
    vmids = [] # unique ovirt ids for vms generated
    hostnames = [] # hostnames assigned to the vms generated
    clustername = None
    if args.count:
        vmids = provision_vms(int(args.count), basename, ovirtcluster, convert_mem_size(ram), cores, user=args.user, tryotherclusters=args.tryotherclusters) # user gives RAM in GB but provision VMs needs Bytes

        if not args.noinstaller:
            # if you supply a value to 'createcluster' arg of initialize_xcalar,
            # then once xcalar install compled on all nodes will form the vms in
            # to a cluster by that name
            if not args.nocluster and int(args.count) > 1:
                clustername = basename
            initialize_xcalar(vmids, licfilepath, installer, createcluster=clustername)

        # get hostnames to print to stdout
        for vmid in vmids:
            hostnames.append(get_hostname(get_vm_ip(vmid)))

    # get summary of work done, while VMs are still ssh'able by ovirttool
    summary_string = get_summary_string(vmids, ram, cores, ovirtcluster, installer=installer, clustername=clustername)

    # setup puppet on all the VMs
    # you can not make any more ssh calls to the VMs after this;
    # ssh'ing is done in this script with a special ovirt pub key
    # puppet will remove it from auth users.
    enable_puppet_on_vms_in_parallel(vmids, args.puppet_role, puppet_cluster=args.puppet_cluster)

    '''
        display a useful summary to user of work done
    '''
    # print hostnames of each created vm to stdout for other scripts to consume
    # (should be only stdout printed by this tool)
    for hostname in hostnames:
        debug_log(hostname) # level 2 is stdout
    info_log(summary_string) # level 0 means you'll print this even on the shell script wrapper

    # close connection
    close_connection(CONN)
