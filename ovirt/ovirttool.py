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
import modules.OvirtUtils

MAX_VMS_ALLOWED=1024

DEFAULT_SSH_USER='root' # what tool will be ssh'ing as.

DEFAULT_OVIRT_CLUSTER="ovirt-node-03-cluster"
#DEFAULT_PUPPET_CLUSTER="ovirt"
DEFAULT_PUPPET_ROLE_INSTALL="xcalar_qa"
DEFAULT_PUPPET_ROLE_NO_INSTALL="jenkins_slave"
DEFAULT_CORES=4
DEFAULT_RAM=8

# want a way to distinguish VMs created by ovirttool;
# will use 'comment' field - it shows up in the official Ovirt GUI,
# in the 'Comment' col of the 'Virtual Machines' tab, for each VM created.
# Below is default comment which will appear, when a user runs this cmd tool directly.
# But there will be other ways to run ovirttool (automated deployments)
# so provide env var which can ovirride with its own comment
# (don't want to --comment cmd arg to this tool, because don't want the cli users
# to set their own; the purpose is to keep track of which VMs were created by this tool
# with some common string.)
VM_COMMENT="ovirttool-cli"
if 'VM_COMMENT' in os.environ:
    VM_COMMENT = os.environ.get('VM_COMMENT')

REBOOT_TIMEOUT=500 # seconds to wait before timing out after waiting to be able to ssh to a VM after 'reboot -h'
SHUTDOWN_TIMEOUT = 600 # seconds to wait before timing out on vms to shut down
POWER_ON_TIMEOUT = 120 # seconds to wait before timing out waiting for a vm to power on
IP_ASSIGN_TIMEOUT = 800 # seconds to wait before timing out waiting for IP to be assigned to newly powered on VM
PUPPET_SETUP_TIMEOUT = 2700 # seconds to wait before timing out puppet setup/puppet agent run
XCALAR_INSTALL_TIMEOUT = 3000 # seconds to wait before timing out on Xcalar install
XCALAR_START_TIMEOUT = 600 # seconds to wait before timing out on service xcalar start
XCALAR_STOP_TIMEOUT = 600 # seconds to wait before timing out on service xcalar stop

NETSTORE_IP='10.10.1.107'
XUID = '1001' # xcalar group uid. hacky fix later
JENKINS_USER_PASS = "jenkins" # password to set for user 'jenkins' on provisioned VMs
LOGIN_UNAME = "admin"
LOGIN_PWORD = "admin"
LICENSE_KEY = "H4sIAAAAAAAAA22OyXaCMABF93yF+1YLSKssWDAKiBRR1LrpCSTWVEhCCIN/Xzu46/JN575AIA4EpsRQJ7IU4QKRBsEtNQ4FKAF/HAWkkBJOYVsID1S4vP4lIwcIMEpKIE6UV/fK/+EO8eYboUy0G+RuG1EQZ4f3w4smuQPDvzduQ2Sosjofm4yPp7IUU4hs2hJhKLL6LGUN4ncpS6/kZ3k19oATKYR54RKQlwgagrdIavAHAaLlyNALsVwhk9nHM7apnvbrc73q9BCh2duxPZbJ4GtPpjy4U6/uHKrBU6U4ijazYekVRDBrEyvJcpUTD+2UB9RfTNtleb0OPbjFl21PqgDvFStyQ2HFrtr7rb/2mZDpYtqmGasTPez0xYAzkeaxmaXFJtj0XiTPmW/lnd5r7NO2ehg4zuULQvloNpIBAAA="
DEFAULT_CFG_PATH="/etc/xcalar/default.cfg"

# names of env vars that can hold ovirt credentials to make this script non-interactive
# (--user arg will take precedence over username env var if both supplied)
UNAME_ENV="OVIRT_UNAME"
PASS_ENV="OVIRT_PASSWORD"
# URLs for ldapConfig files that can be curld in to xcalar root after an install
# (can specify key to --ldap, and will use that key's value)
LDAP_CONFIGS = {
    'test': "http://freenas2.int.xcalar.com:8080/netstore/infra/ldap/ldapConfig.json",
    'xcalar': "http://freenas2.int.xcalar.com:8080/netstore/infra/ldap/sso/ldapConfig.json" # using this ldapConfig will allow any Xcalar employee to log in with ldap credentials
}

OVIRT_TEMPLATE_MAPPING = {
    'ovirt-node-03-cluster': 'el7-test-template-node-03-1',
    'einstein-cluster2': 'ovirt-tool-einstein-updated',
    'node2-cluster': 'ovirt-cli-tool-node2-template',
    'node3-cluster': 'ovirt-cli-tool-node3-template'
}

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))

TMPDIR_LOCAL='/tmp/ovirt_tool' # tmp dir to create on local machine running python script, to hold pem cert for connecting to Ovirt
TMPDIR_VM='/tmp/ovirt_tool' # tmp dir to create on VMs to hold helper shell scripts, lic files (dont put timestamp because forking processes during install processing)
CLUSTER_DIR_VM='/mnt/xcalar' # if creating cluster of the VMs and need to mount netstore, will be local dir to create on VMs, to mount shared storage space to.

# location of puppet lock file on a VM to check if puppet service
# is running (won't run puppet agent if this file present)
PUPPET_LOCK_FILE='/var/run/puppetlabs/agent_catalog_run.lock'

OVIRT_KEYFILE_SRC = 'id_ovirt' # this a file to supply during ssh.  need to chmod it for scp but dont want it to show up in users git status, so this its loca nd will move it to chmod
home = os.path.expanduser('~') # '~' gives issues with paramiko; expand to home dir, this swill work cross-platform
OVIRT_KEYFILE_DEST = home + '/.ssh/id_ovirt'

def generate_random_string(length=5, exclude=[]):
    rand_string = None
    while not rand_string or any(str(i) in rand_string for i in exclude):
        rand_string = ''.join([random.choice(string.ascii_letters + string.digits) for n in range(length)])
    return rand_string

OVIRT_SHELL_LOGS_DIR = '/tmp/ovirtShellScriptLogs_' + generate_random_string() # dir on created VMs to hold redirected shell script output

CONN=None
LICFILENAME='XcalarLic.key'
# helper scripts - they should be located in dir this python script is at
DEFAULT_ADMIN_FILE = 'defaultAdmin.json'
INSTALLER_SH_SCRIPT = 'e2einstaller.sh'
TEMPLATE_HELPER_SH_SCRIPT = 'templatehelper.sh'
ADMIN_HELPER_SH_SCRIPT = 'setupadmin.sh'

FORCE = False # a force option will allow certain operations when script would fail otherwise (use arg)

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
def debug_log(string, timestamp=True):
    loggit(string, level=1, timestamp=timestamp)
def info_log(string, timestamp=True):
    loggit(string, level=0, timestamp=timestamp)
def warn_log(string, timestamp=True):
    loggit(string, level=2, timestamp=timestamp)
''' don't call this one directly, use the aux methods above '''
def loggit(string, level=1, timestamp=True):
    level_prefixes={0:"{}",1:"DEBUG: {}",2:"WARN: {}"}
    # timestamp if requested, else will put nothing there
    meta_str = ""
    if timestamp:
        st = datetime.datetime.utcnow()
        meta_str = "{} ".format(st)
    # split on any newline chars, and print each with the prefix
    for line in string.split("\n"):
        print("{}".format(meta_str) + level_prefixes[level].format(line), file=sys.stdout)

'''
    OVIRT SDK FUNCTIONS
'''

'''
    Generate n vm names not currently in use by Ovirt, given some basename.
    Unless 'no_rand' option supplied, will add random chars to basename to try to avoid
    re-using hostnames of deleted VMs which would cause issues in puppet.  (No database
    of old names to check against.).  then bases the individual vm names on this.
    if n > 1, tacks counter on individual vmnames

    @Returns <unique basename the vm names based on>, <list of all the vm names>

    @examples:
    generate_vm_names("myvm", n=1)
    could return: "myvm-6qyu", ["myvm-6qyu"]

    generate_vm_names("myvm", n=2)
    could return: "myvm-a2j4", ["myvm-a2j4-vm0", "myvm-vm1"]

    @no_rand: if True, will not append the random seq. of chars in generated names.
    use at own risk.
'''
def generate_vm_names(basename, n, no_rand=False):
    unique_basename = None

    # a unique basename to base all the n vm names from
    if no_rand:
        unique_basename = basename
    else:
        # tack random chars on the basename.
        # keep trying random strings on basename until you hit a combo not in ovirt
        # don't check for exact equality when checking if in Ovirt - since will
        # append -vm0, -vm1, etc. if multiple VMs.  this will return if there's any
        # vm in ovirt with this as a substring
        while not unique_basename or get_matching_vms(unique_basename):
            # don't use L's or I's; they look same in ovirt console; zero will look like 'O'
            # hostnames need to be lowercase else can cause conflicts with other scripts
            rand_seq = generate_random_string(4, exclude=["i","l","I","L","0"]).lower()
            unique_basename = "{}-{}".format(basename, rand_seq)

    # generate n vm names using the unique_basename
    vm_names = []
    # if just 1, don't put counters on it
    if n == 1:
        vm_names = [unique_basename]
    else:
        for i in range(n):
            vm_names.append("{}-vm{}".format(unique_basename, i))

    # loop through convert everything to lower case just to make sure
    for i in range(len(vm_names)):
        vm_names[i] = vm_names[i].lower()

    # make sure all generated names unique in existing Ovirt
    # this will NOT check if there are previous VMs by this name which has been deleted
    # but will make sure no current VMs in Ovirt with any of the assigned names
    for full_name in vm_names:
        if get_matching_vms("name=" + full_name):
            raise ValueError("\n\nOne of the generated VM names is currently in "
                "use by Ovirt: {}"
                "\nIf you used -nr/--norand option, please re-run without this option "
                "or supply a name which is not already in use.  (Note: It should "
                "be a name which has NEVER been used in Ovirt; even by deleted "
                "VMs which no longer show up!)\n".format(full_name))

    return unique_basename, vm_names

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
        info_log("Check and wait for any current power downs to complete " \
            "on {}, before starting service".format(name))
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
        assigned_ip = wait_for_ip(vmid, ip_assign_timeout)
        info_log("IP {} has been assigned to {}".format(assigned_ip, name))
        return assigned_ip

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
            comment=VM_COMMENT,
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
                " if so, please modify this tool and add to PROTECTED_KEYWORDS list in modules/OvirtUtils.py so vms of this name"
                " will not be allowed)\n"
                "If not - Open ovirt, and try to type this name in the main search bar."
                " are there any results?  If so, this indicates something is wrong with the API".format(name, name))

        # start vm and bring up until IP is displaying in Ovirt
        debug_log("Bring up {}...".format(vmid))
        # sometimes IP not coming up first time around.  restart and ty again
        triesleft = iptries
        assigned_ip = None
        while triesleft:
            try:
                time.sleep(5)
                assigned_ip = bring_up_vm(vmid, waitForIP=True)
                break
            except NoIpException:
                debug_log("WARNING: Timed out waiting for IP on new VM... will restart and try again...")
                triesleft -= 1
                stop_vm(vmid)

        if not assigned_ip:
            raise RuntimeError("ERROR: Never got Ip for {}/[id:{}],\n"
                " even after {} restarts (dhcp issue?)\n".format(name, vmid, iptries))

        # IP came up, but make sure it is actually unique to this new VM for Ovirt (feynman issue)
        # args is search string to use in ovirt search bar; search by actual ip
        # else just supplying ip would return superstrings of that ip too
        matchingVMs = get_matching_vms("ip=" + assigned_ip)
        if len(matchingVMs) > 1:
            info_log("IP that got assigned to {}, {}, " \
                "registered to another VM in Ovirt... " \
                "(probably due to Feynman outage) " \
                "going to delete vm and re-try".format(name, assigned_ip))
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
        assigned_ip = wait_for_ip(vmid, ip_assign_timeout)
        if assigned_ip != ip:
            debug_log("WARNING: node {} came up after reboot, but in Ovirt now is " \
                " assigned as IP {}".format(ip, assigned_ip))

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

    # some follow up commands, to make sure netstore accessible
    # been going down after puppet agent.  maybe temp issue?
    follow_up_cmds = [
        ['sudo systemctl restart autofs'], # won't be able to ssh as root after puppet runs
        ['ls /netstore/']
    ]
    info_log("Run follow up cmds ({}) to ensure netstore " \
        "mounted".format(", ".join(item[0] for item in follow_up_cmds)))
    run_ssh_cmds(ip, follow_up_cmds)

'''
    setup puppet on all nodes in parallel
'''
def enable_puppet_on_vms_in_parallel(vmids, puppet_role, puppet_cluster=None, puppet_agent_timeout=PUPPET_SETUP_TIMEOUT):

    debug_log("Setup puppet on all nodes in parallel")

    procs = []
    sleep_between = 5
    sleep_offset = 0
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
        sleep_offset+=sleep_between

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
    search_str = pyString(identifier)
    matching_vms = vms_service.list(search=search_str)
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
    name_search="name={}".format(identifier)
    ip_search="ip={}".format(identifier)
    debug_log("Search by {}".format(name_search))
    vmid = get_vm_id(name_search, failOnNoMatches=failOnNoMatches)
    if not vmid:
        debug_log("Search by {}".format(ip_search))
        vmid = get_vm_id(ip_search, failOnNoMatches=failOnNoMatches)
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
    Return list of strings containing data of each VM in Ovirt
    :parm verbose:
        if True: each line formatted with hostname, ip, status
            (takes much longer, depending on how many VMs are in Ovirt)
            for VMs without an IP, prints '-'
        if False, each line just contains vm hostname (quick)
    :param formatted:
        if True, pretty-prints so cols are aligned
'''
def get_all_vms(verbose=False, formatted=False):

    vms_service = CONN.system_service().vms_service()
    vms = vms_service.list()
    vm_list = []
    # col widths get set if formatted past; they expand if width longer then specified
    name_col_w = 0
    ip_col_w = 0
    status_col_w = 0
    # set col widths if formatting
    # (only do in verbose case since regular only contains one col)
    if verbose and formatted:
        ip_col_w = 20
        status_col_w = 10
        # name width make length of longest hostname
        for vm in vms:
            name_col_w = max(name_col_w, len(vm.name))
    for vm in vms:
        vm_name = vm.name
        vm_line = ""
        # getting all IPs can take a long time... make it optional
        if verbose:
            vm_id = vm.id
            vm_ip = "-" # if None, print formatting will fail
            try:
                vm_ip = get_vm_ip(vm_id)
            except NoIpException:
                pass
            vm_status = vm.status
            vm_line = '{:<{}} {:<{}} {:<{}}'.format(vm_name, name_col_w, vm_ip, ip_col_w, vm_status, status_col_w)
        else:
            vm_line = vm_name
        vm_list.append(vm_line)
    return vm_list

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
            assigned_ip = wait_for_ip(vmid, IP_ASSIGN_TIMEOUT)
            if assigned_ip is None:
                raise Exception("LOGIC ERROR:: wait_for_ip returns without " \
                    " NoIpException, but ip returned is none. Please sync code")
            else:
                info_log("Found IP of VM: {}".format(assigned_ip))

                info_log("Release {}/{} from consul".format(name, assigned_ip))
                # if puppet wasn't set up, might not work, just catch and go on
                try:
                    run_ssh_cmd(assigned_ip, "consul leave")
                except Exception as e:
                    debug_log("consul leave command failed on {}, Reason: {}" \
                        "; ignoring".format(assigned_ip, str(e)))

                info_log("Release IP {}".format(assigned_ip))
                cmds = [['sudo dhclient -v -r']] # assuming Centos7... @TODO for other cases?
                run_ssh_cmds(assigned_ip, cmds)

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
    sleep_between = 5
    sleep_offset = 0
    for vm in vms:
        proc = multiprocessing.Process(target=remove_vm, args=(vm,), kwargs={'releaseIP':releaseIP})
        proc.start()
        procs.append(proc)
        time.sleep(sleep_between)
        sleep_offset += sleep_between

    # wait for the processes
    process_wait(procs, timeout=500+sleep_offset)

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
    sleep_between = 5
    sleep_offset = 0
    for vm in vms:
        proc = multiprocessing.Process(target=shutdown_vm, args=(vm, SHUTDOWN_TIMEOUT))
        proc.start()
        procs.append(proc)
        time.sleep(sleep_between)
        sleep_offset += sleep_between

    # wait for the processes
    process_wait(procs, timeout=SHUTDOWN_TIMEOUT+sleep_offset)

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
    sleep_between = 5
    sleep_offset = 0
    for vm in vms:
        vmid = find_vm_id_from_identifier(vm)
        proc = multiprocessing.Process(target=bring_up_vm, args=(vmid,), kwargs={
            'waitForIP':True,
            'power_on_timeout': POWER_ON_TIMEOUT,
            'ip_assign_timeout': IP_ASSIGN_TIMEOUT
        })
        proc.start()
        procs.append(proc)
        time.sleep(sleep_between)
        sleep_offset += sleep_between

    # wait for the processes
    process_wait(procs, timeout=POWER_ON_TIMEOUT + IP_ASSIGN_TIMEOUT +sleep_offset)

'''
    reboot nodes in parallel.  Optionally wait for all nodes to come up
'''
def reboot_nodes(vmids, waitForNodesToComeUp=True):

    debug_log("Reboot nodes in parallel")

    procs = []
    sleep_between = 5
    sleep_offset = 0
    for vmid in vmids:
        ip = get_vm_ip(vmid)
        proc = multiprocessing.Process(target=reboot_node, args=(ip,), kwargs={
            'waitForVmToComeUp': waitForNodesToComeUp,
            'reboot_timeout': REBOOT_TIMEOUT,
            'ip_assign_timeout': IP_ASSIGN_TIMEOUT
        })
        proc.start()
        procs.append(proc)
        sleep_offset+=sleep_between

    # wait for the processes
    process_wait(procs, timeout=sleep_offset + REBOOT_TIMEOUT + IP_ASSIGN_TIMEOUT)

'''
    Open connection to Ovirt engine.
    (sdk advises to free up this resource when possible)

    :returns: ovirtsdk4:Connection object
'''
def open_connection(user=None):

    info_log("Open connection to Ovirt engine...")

    # get username if user didn't supply when calling script
    if not user:
        # check if its an env variable
        if UNAME_ENV in os.environ:
            user=os.environ.get(UNAME_ENV)
        else:
            # get user name
            user = input('Username: ')

    # take the ldap username and convert to login needed by oivrt specifying profile

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
    if PASS_ENV in os.environ:
        password=os.environ.get(PASS_ENV)
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
    err_msg = "\n\nERROR: There are not enough resources available " \
        " to provision the next VM of {} bytes RAM, {} cores\n" \
        " Tried on clusters: {}".format(ram, cores, availableClusters)
    debug_log(err_msg)
    sys.exit(1) # do a sys exit instead of raising exception because then this process will terminate
    # elses if its being called as a subprocess you're going to have to wait for it to time out
    #raise Exception(err_msg)

'''
    provisions n vms in parallel.
    waits for all vms to come up with ips displaying
    Return a list of names of vms created in Ovirt

    :param vmnames: names to give to the VMs
    :param ovirt_cluster: which cluster in Ovirt to create VMs from
    :param ram: (int) memory (in GB) on each VM
    :param cores: (int) num cores on each VM

    :returns: list of unique vm ids for each VM created
        (this is distinct from name; its id attr of Type:Vm Object)

'''
def provision_vms(vmnames, ovirt_cluster, ram, cores, tryotherclusters=True):

    if not vmnames: # no vms to create
        return None

    if not ram or not cores:
        raise ValueError("ERROR: No value for ram or cores args to provision_vms\n"
            " (perhaps default values changed for the --ram or --cores options?)\n")

    info_log("Provision {} vms on ovirt node {} ({}), " \
        "in parallel".format(len(vmnames), ovirt_cluster, ", ".join(vmnames)))

    '''
        get list of cluster we can try to provision the VMs on.
        (if tryotherclusters is True, then can try on other clusters
        other than one specified by ovirt_cluster param, in case something
        goes wrong on that cluster)
    '''
    availableClusters = [ovirt_cluster]
    if tryotherclusters:
        availableClusters = get_cluster_priority(prioritize=ovirt_cluster)
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
        availableClusters = enough_memory(len(vmnames), ram, availableClusters)
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
    sleep_between = 20
    for nextvmname in vmnames:
        debug_log("Fork new process to create a new VM by name {}".format(nextvmname))
        proc = multiprocessing.Process(target=provision_vm, args=(nextvmname, ram, cores, availableClusters))
        #proc = multiprocessing.Process(target=create_vm, args=(newvm, ovirt_cluster, template, ram, cores)) # 'cluster' here refers to cluster the VM is on in Ovirt
        # it will fail if you try to create VMs at exact same time so sleep
        proc.start()
        procs.append(proc)
        time.sleep(sleep_between)

    # TODO: Deal with 'image locked' status because of network issue on node

    # wait for the processes
    process_wait(procs, timeout=4000+sleep_between*len(vmnames), valid_exit_codes=[0, 2]) # 0 and 2 both valid exit code for puppet which will get set up

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

    # sudo in case running after puppet setup, in which case no root ssh
    startCmd = 'sudo service xcalar start'
    info_log("Start Xcalar service on {} via {}".format(node, startCmd))
    cmds = [[startCmd, XCALAR_START_TIMEOUT]]
    run_ssh_cmds(node, cmds)

'''
    Bring down Xcalar service on node

    :paran node: (String) ip of node to stop xcalar service on
    :param stop_supervisor: if True, will stop expServer, too
'''
def stop_xcalar(node, stop_supervisor=False):

    # sudo in case running after puppet setup, in which case no root ssh
    stop_cmd = 'sudo service xcalar stop'
    # stop-supervisor will bring down expServer too
    if stop_supervisor:
        stop_cmd += '-supervisor'
    info_log("Stop Xcalar service on {} via {}".format(node, stop_cmd))
    cmds = [[stop_cmd, XCALAR_STOP_TIMEOUT]]
    run_ssh_cmds(node, cmds)

def restart_xcalar(node, restart_expserver=False):
    stop_xcalar(node, stop_supervisor=restart_expserver)
    start_xcalar(node)


''' parallel versions '''

def start_xcalar_in_parallel(nodes):
    debug_log("Start Xcalar in parallel on the following nodes: {}".format(", ".join(nodes)))
    procs = []
    sleep_between = 20
    for node in nodes:
        proc = multiprocessing.Process(target=start_xcalar, args=(node,)) # need comma because 1-el tuple
        procs.append(proc)
        proc.start()
        time.sleep(sleep_between)

    # wait
    process_wait(procs, timeout=XCALAR_START_TIMEOUT+sleep_between*len(nodes))

def stop_xcalar_in_parallel(nodes, stop_supervisor=False):
    debug_log("Stop Xcalar in parallel on the following nodes: {}".format(", ".join(nodes)))
    procs = []
    sleep_between = 20
    for node in nodes:
        proc = multiprocessing.Process(target=stop_xcalar, args=(node,), kwargs={
            'stop_supervisor': stop_supervisor,
        })
        procs.append(proc)
        proc.start()
        time.sleep(sleep_between)

    # wait
    process_wait(procs, timeout=XCALAR_STOP_TIMEOUT+sleep_between*len(nodes))

def restart_xcalar_in_parallel(nodes, restart_expserver=False):

    info_log("Restart Xcalar in parallel on the following nodes: {}".format(", ".join(nodes)))
    stop_xcalar_in_parallel(nodes, stop_supervisor=restart_expserver)
    start_xcalar_in_parallel(nodes)

'''
    Setup admin account and ldap on a node
    Note - if Xcalar was already running, ldap changes won't take effect until
    Xcalar is restarted.

    :param node: (String) ip of node to setup admin account on
    :param ldap_config_url: (String) curl'able URL for an an ldapConfig.json file to use
'''
def setup_admin_account(node, ldap_config_url):

    info_log("Setup admin account on {}".format(node))

    # scp in shell script that sets up default admin account; it looks for
    # defaultAdmin.json at vm's root
    scp_file(node, SCRIPT_DIR + '/../docker/xpe/staticfiles/defaultAdmin.json', '/')
    scp_file(node, SCRIPT_DIR + '/' + ADMIN_HELPER_SH_SCRIPT, TMPDIR_VM)
    # run the helper script
    run_sh_script(node, TMPDIR_VM + '/' + ADMIN_HELPER_SH_SCRIPT, scriptvars=["LDAP_CONFIG_URL=" + ldap_config_url])

'''
    Install xcalar on VM of given id
    Copy in helper shell scripts used for instlalation
    start service if requested

    :param ip: (String)
        IP of VM to install Xcalar on
    :param uncompressed_xcalar_license_string: (String)
        an uncompressed Xcalar license
    :param installer: (String)
        URL for an RPM installer on netstore (valid URL user should be able to curl)
    :param node_0_val (String)
        Val to set for default.cfg Node.0.IpAddr (gets overiwrriten if this becomes a cluster)
        (Use "localhost" if you don't care about listening to outside requests,
        will always work regardless of Ovirt DNS; use the vm's hostname (short version
        without .int.xcalar.com) if you need to listen to outside requets)
    :param startXcalar (boolean)
        start Xcalar after the install

'''
def install_xcalar(ip, uncompressed_xcalar_license_string, installer, node_0_val, startXcalar=True):

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
        [SCRIPT_DIR + '/' + TEMPLATE_HELPER_SH_SCRIPT, TMPDIR_VM]] # installer script will call this template helper script
    for filedata in fileslist:
        scp_file(ip, filedata[0], filedata[1])

    # echo licdata to licfile on vm.
    # e2e installer script will look for lic file in this specific location
    lic_file_vm = TMPDIR_VM + '/' + LICFILENAME
    run_ssh_cmd(ip, "echo '{}' > {}".format(uncompressed_xcalar_license_string, lic_file_vm))

    # install using bld requested
    run_sh_script(ip, TMPDIR_VM + '/' + INSTALLER_SH_SCRIPT, script_args=[installer, ip], timeout=XCALAR_INSTALL_TIMEOUT)

    # set Node.0.IpAddr val in default.cfg::
    # In default.cfg, default val of Node.0.IpAddr in SINGLE NODE case is
    #'localhost' (can't listen to outside requests but doesn't depend on DNS working.)
    # if set as Vm's hostname, can listen to outside requests but will depend on Ovirt DNS to work.
    # waant to listen in some scenarios (release tests running on Ovirt: Jenkins slaves will
    # use xccli to query the provisioned Ovirt VM if Xcalar is up), but not majority
    # therefore, make it configuraable, as 'localhost' will always work
    # cluster creation will overwrite this but happens after install_xcalar
    node_param="Node.0.IpAddr"
    sed_cmd="sudo sed -i 's@^{}=.*$@{}={}@g' {}".format(node_param, node_param, node_0_val, DEFAULT_CFG_PATH)
    debug_log("Set {} in {} as: {}, using sed cmd: {} (will get reset if " \
        "node becomes part of cluster)".format(node_param, DEFAULT_CFG_PATH, node_0_val, sed_cmd))
    run_ssh_cmd(ip, sed_cmd)

    if startXcalar:
        # start xcalar
        start_xcalar(ip)

'''
    Install and setup Xcalar on a set of nodes.
    Once xcalar installation completes on all of them,
    form in to a cluster unless specified otherwise

    :param vmids: list of unique vm ids in Ovirt of VMs to install xcalar on
    :param uncompressed_xcalar_license_string: (String)
        an uncompressed Xcalar license
    :param installer (String)
        curl'able URL to an RPM installer
    :param ldap_config_url (String)
        curl'able URL of an ldapConfig.json file to put in xcalar root post-install
    :param listen (boolean)
        if True: Node.0.IpAddr gets set to hostname on single node VMs
            (works as long as Ovirt DNS works, and allows listening to outside requests)
        if False: stays as "localhost"
            (works regardless of Ovirt DNS, but can't listen to outside requests)
    :param createcluster: (optional, String)
        If supplied, then once xcalar setup on the vms, will form them
        in to a cluster by name of String passed in
        If not supplied will leave nodes as individual VMs

'''
def setup_xcalar(vmids, uncompressed_xcalar_license_string, installer, ldap_config_url, listen, createcluster=None):

    debug_log("installer: " + str(installer))
    debug_log("Setup xcalar on node set and cluster {}".format(createcluster))

    procs = []
    ips = []

    setup_admin_account_on = [] # set on all nodes, unless cluster use just one (they'll have shared storage)

    sleep_between = 15
    for vmid in vmids:
        # get ip
        ip = get_vm_ip(vmid)
        name = get_vm_name(vmid)
        ips.append(ip)
        debug_log("Start new process to setup xcalar on {}, {}".format(name, ip))
        # val to set for Node.0.IpAddr in default.cfg; "localhost" will always work
        # but won't be able to listen to outside requests so make it optional to set
        node_0_val = "localhost"
        if listen:
            node_0_val = name
        # bring up Xcalar only after cluster create and/or admin/ldap setup
        proc = multiprocessing.Process(target=install_xcalar, args=(ip, uncompressed_xcalar_license_string, installer, node_0_val), kwargs={
            'startXcalar': False
        })
        # failing if i dont sleep in between.  think it might just be on when using the SDK, similar operations on the vms service
        procs.append(proc)
        proc.start()
        time.sleep(sleep_between)

    # wait
    process_wait(procs, timeout=1500+sleep_between*len(vmids))

    # form the nodes in to a cluster if requested (will need to start Xcalar on nodes to take effect)
    setup_admin_account_on = ips
    if createcluster and len(ips) > 1:
        create_cluster(ips, createcluster)
        setup_admin_account_on = [ips[0]] # only need set it up on one

    # tasks to be done post-install and post-cluster (if cluster),
    # which would be cluster specific (not node specific)

    '''
        setup admin account and ldap setup.
        (doing here instead of in initial setup, because for cluster nodes,
        cluster needs to be created before admin account can get setup in shared storage)
    '''
    procs = []
    sleep_between = 20
    for ip in setup_admin_account_on:
        proc = multiprocessing.Process(target=setup_admin_account, args=(ip, ldap_config_url))
        procs.append(proc)
        proc.start()
        time.sleep(sleep_between)

    # wait for all the processes to complete successfully
    process_wait(procs, timeout=600+sleep_between*len(ips))

    # start Xcalar in parallel on all the nodes
    # (if creating cluster bring up as cluster nodes now)
    # also, so ldap configurations will take effect after setup_admin_account
    restart_xcalar_in_parallel(ips)

'''
        FOR CLUSTER SETUP
'''

'''
    Given a list of node IPs, create a shared space for those
    nodes, and form the nodes in to a cluster.

    :param nodeips: (list of Strings)
        list of IPs of the nodes you want made in to a cluster
    :param cluster_name: (String)
        name you want the cluster to be
        ('cluster name' here meaning it will become dir name of shared storage space on netstore)

    @TODO: 'start' boolean param that controls if you start xcalar after cluster configured
        to pass in to child proc

    NOTE: Won't take effect until Xcalar is restarted
'''
def create_cluster(nodeips, cluster_name):

    if not len(nodeips):
        raise ValueError("ERROR: Empty list of node ips passed to create_cluster;"
            " No nodes  make cluster on!\n")

    '''
        Create a shared storage space for the nodes
        on netstore, using cluster name
    '''
    shared_remote_storage_path = 'ovirtgen/' + cluster_name
    create_cluster_dir(shared_remote_storage_path)

    # for each node, generate config file with the nodelist
    # and then bring up the xcalar service
    info_log("Create cluster using nodes : {}".format(nodeips))
    procs = []
    sleep_between = 15
    for ip in nodeips:
        debug_log("\tFork cluster config for {}\n".format(ip))
        '''
        Note: The order of the ips in nodeips list is important!!
        Will be node 0 (root cluster node), node1, etc., in order of list
        '''
        proc = multiprocessing.Process(target=configure_cluster_node, args=(ip, nodeips, NETSTORE_IP, shared_remote_storage_path))
        procs.append(proc)
        proc.start()
        time.sleep(sleep_between)

    # wait for all the proceses to complte
    process_wait(procs, timeout=600+sleep_between*len(nodeips))

'''
    Create a directory on netstore intended to be shared
    storage by all nodes in the cluster.

    :param remote_path: (String)
        path on the remote_IP to use as the shared cluster storage

    @TODO:
        Handle taking a general IP (and credentials?) in case ever want
        to create the shared storage somewhere other than netstore
'''
def create_cluster_dir(remote_path):

    # -m 0777 needed because xcalar needs to be owner but can't chown after rootsquash
    dir_path = '/netstore/' + remote_path
    info_log("Create shared cluster storage on netstore: {}".format(dir_path))
    cmds = ['mkdir -p -m 0777 ' + dir_path]
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
    :pararm remote_IP: (String)
        IP of the machine with the shared cluster storage
    :param remoteClusterStoragePath: (String)
        remote path remote_IP for the shared cluster storage for the nodes

'''
def configure_cluster_node(node, clusternodes, remote_IP, remoteClusterStoragePath):

    debug_log("Configure node {} as part of cluster nodes: {}\n".format(node, clusternodes))

    debug_log("get node's local path to the shared cluster storage directory on netstore, {}".format(remoteClusterStoragePath))
    local_cluster_storage_dir = setup_cluster_storage(node, remote_IP, remoteClusterStoragePath)

    debug_log("generate cluster template file...")
    generate_cluster_template_file(node, clusternodes, local_cluster_storage_dir)

'''
    Setup access to remote cluster storage on to the node

    :paran node: (String)
        IP of the node to set shared storage on
    :param remote_IP: (String)
        IP of the machine with the shared storage
        (right now always using netstore - adding this in so it will be
        easy to change things)
    :param remote_path: (String) path on netstore to shared storage

    :returns: (String)
        local path on the node, to the shared cluster storage
'''
def setup_cluster_storage(node, remote_IP, remote_path):

    debug_log("Determine local path VM {} should use for xcalar home "
        " (Constants.XcalarRootCompletePath var in {}".format(node, DEFAULT_CFG_PATH))

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
    netstore_mount_dir = "/netstore"
    possible_path = netstore_mount_dir + "/" + remote_path
    while tries:
        if path_exists_on_node(node, possible_path):
            info_log("Shared cluster storage already accessible to node {}, at {}".format(node, possible_path))
            return possible_path
        time.sleep(5)
        tries -= 1

    # if here, was not able to access through the possible path, even accounting
    # for automount lags.  Mount netstore directly
    # (the method called will return the local dir to the remote shared storage that results after successful mount)
    return mount_shared_cluster_storage(node, remote_IP, remote_path, netstore_mount_dir)

'''
    Mount a directory on Netstore provisioned for shared cluster storage,
    on a cluster node.

    :param node: (String)
        IP of node to mount the storage space on
    :param remote_IP: (String)
        IP of the machine with the shared storage space
    :param remote_path: (String)
        Path on on remote_IP to shared storage space
    :param mount_dir: (String)
        local directory to mount remote_IP to
        (NOT local dir to remote_path)

    :returns (String)
        local path on node, to the shared cluster storage (remote_IP's remote_path)

'''
def mount_shared_cluster_storage(node, remote_IP, remote_path, mount_dir):

    info_log("Mount netstore directory {} to {} on {} as shared cluster storage\n"
        .format(remote_path, mount_dir, node))

    '''
        add nfs mount instructions for netstore, in to fstab,
        then mount from that
        (having the instructions in fstab will mount again if node reboots)
    '''
    fs_tab_entry = "{}: {} {} nfs rsize=8192,wsize=8192,timeo=14,intr".format(remote_IP, remote_path, mount_dir)
    run_ssh_cmd(node, "echo '{}' >> /etc/fstab".format(fs_tab_entry))
    # now that it's in fstab, can mount via the specified mount point
    # (the mount point must exist first)
    run_ssh_cmd(node, "mkdir -p {}; mount {}".format(mount_dir, mount_dir), timeout=400)

    '''
        make sure the shared cluster storage
        now accessible on the node
    '''
    shared_storage_local_dir = mount_dir + "/" + remote_path
    if not path_exists_on_node(node, shared_storage_local_dir):
        raise RuntimeError("Shared cluster storage dir on netstore, {}, not accessible locally on node {}, even after nfs mount".format(remote_path, node))

    return shared_storage_local_dir

'''
    Generate template file for node
    (/etc/xcalar/default.cfg file, on the node)

    :param node: (String) ip of node to generate cfg file for
    :clusternodes: list of Strings: list of ips of nodes in the cluster
        ORDER IS IMPORTANT
        clusternodes[0] : root node (node 0)
        clusternodes[1] : node1
        ... etc  <that's how the shell script being called should work>
    :param xcalar_root: (String) local path on the node to shared storage
        (val you want for Constants.XcalarRootCompletePath in the cg file)
'''
def generate_cluster_template_file(node, clusternodes, xcalar_root):

    debug_log("Generate {} file for node {}, set with cluster nodes {}\n".format(DEFAULT_CFG_PATH, node, clusternodes))

    # there's a shell script for that
    nodeliststr = ' '.join(clusternodes)
    #scp_file(node, TEMPLATE_HELPER_SH_SCRIPT, TMPDIR_VM) # the e2e installer needs this script too so if it's not present I want this to fail
    # so don't copy it in
    run_sh_script(node, TMPDIR_VM + '/' + TEMPLATE_HELPER_SH_SCRIPT, script_args=[xcalar_root, nodeliststr])

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
def get_template(ovirt_cluster):

    '''
    @TODO:
        Select the template based on their preferences
        of RAM, etc.
        For now, just base on the ovirt cluster specified
    '''

    # make so the value is a hash with keys for RAM, cores, etc.
    #and appropriate template for now just one std template each
    # check that the node arg a valid option
    if ovirt_cluster in OVIRT_TEMPLATE_MAPPING.keys():
        ## todo - there should be templates for all the possible ram/cores/etc configs
        return OVIRT_TEMPLATE_MAPPING[ovirt_cluster]
    else:
        raise AttributeError("ERROR: No template found for ovirt node {}."
            "\nValid nodes with templates: {}\n".format(ovirt_cluster, ", ".join(OVIRT_TEMPLATE_MAPPING.keys())))

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
    returns stdout

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
        cmd_out = subprocess.check_output(cmd, shell=True)
        #cmd_out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True) # this will route stderr to stdout too
        cmd_out_str = cmd_out.decode("utf-8") # haven't checked this against python 2
        return cmd_out_str
    except subprocess.CalledProcessError as e:
        info_log("Stderr: {}\n\nGot error when running sys command {}:\n{}".format(str(e.stderr), cmd, str(e.output))) # str on output in case None
        raise e

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
    :param script_args:
        (list) list of Strings as positional args to supply to shell script after
    :param scriptvars:
        (list) list of Strings as vars to supply in front of shell script call
    :redirect:
        if True will redirct shell output on node to OVIRT_SHELL_LOGS_DIR
        (if dir does not exist on node will create it)
    :debug:
        if True will run bash with -x option

'''
def run_sh_script(node, path, script_args=[], scriptvars=[], timeout=120, redirect=True, debug=True):

    debug_log("Run shell script {} on node {}...\n".format(path, node))

    bash_call = '/bin/bash'
    if debug:
        bash_call += ' -x'
    shell_cmd = " ".join(scriptvars) + " " + bash_call + ' ' + path + ' ' + ' '.join(script_args)
    cmds = []
    output_file = None
    if redirect:
        cmds.append(['mkdir -p ' + OVIRT_SHELL_LOGS_DIR])
        output_file = OVIRT_SHELL_LOGS_DIR + "/" + os.path.basename(path) + "_log"
        shell_cmd += ' &> ' + output_file
    cmds.append([shell_cmd, timeout])
    try:
        run_ssh_cmds(node, cmds)
    except ShellError as e:
        errInfo = "\nHit error running shell script {} on {}.  ERROR: {}".format(path, node, e.summary)
        if output_file: # no stderr to print to them it was all redirected
            errInfo += "\nLogfile for this shell script @ {} on {}\n".format(output_file, node)
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

    caddy_info = []

    caddyfile_path = "/etc/xcalar/Caddyfile"
    # should be a main line in Caddyfile of format http|https://0.0.0.0<:port>
    grep_cmd = "grep -oP '(http|https)://0\.0\.0\.0:(\d+)' " + caddyfile_path

    # first make sure that line exists (helpful to check for this line not being there
    # in case the next grep commands return no output)
    status, stdout, stderr = run_ssh_cmd(ip, grep_cmd)
    if not stdout:
        raise ValueError("Could not get main proxy line from Caddyfile {} on {}" \
            "\n(Used grep cmd: {} - Does it need to be updated?)".format(caddyfile_path, ip, grep_cmd))

    # determine if http or https by piping in to another grep
    # (doing 2 greps so don't catch http as subset of https)
    status, stdout, stderr = run_ssh_cmd(ip, grep_cmd + " | grep -oP '(http:|https:)' | grep -oP '(\w+)'")
    if not stdout:
        raise ValueError("Couldn't determine http vs. https from Caddyfile")
    protocol = stdout.strip()

    # now get the port
    status, stdout, stderr = run_ssh_cmd(ip, grep_cmd + " | grep -oP ':(\d+)' | grep -oP '(\d+)'")
    if not stdout:
        raise ValueError("Couldn't determine port from Caddyfile")
    port = stdout.strip()

    caddy_info = [protocol, port]
    return caddy_info

'''
    Given an IP of a node with xcalar installed,
    display a correct access URL for that machine based on its Caddy configuration
'''
def get_access_url(ip):
    caddy_info = get_caddy_config_debug_log(ip)
    caddy_protocol = caddy_info[0]
    caddy_port = caddy_info[1]
    hostname = get_hostname(ip)
    access_url_base = "{}://{}.int.xcalar.com".format(caddy_protocol, hostname)
    display_url = access_url_base
    # add port to dispaly url if it's not default port
    if not (caddy_port == "443" and caddy_protocol == "https") and not (caddy_port == "80" and caddy_protocol == "http"):
        display_url = "{}:{}".format(access_url_base, caddy_port)
    return display_url

solid_line = "====================================================="
dotted_line = "-----------------------------------------------------"
jenkins_summary_grep_start = "-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-"
jenkins_summary_grep_stop = "~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~"

'''
    Returns a summary string with debugrmation about vms
'''
def summary_str_created_vms(vmids, ram, cores, ovirt_cluster, installer=None, cluster_name=None):

    notes = []
    # add note and return a (see note) text with corresponding amount of * so itll match in summary
    def add_note(note):
        notes.append(note)
        return "*"*(len(notes)) + " (see note)"

    created_vms_summary = solid_line + "\n" \
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
            created_vms_summary = created_vms_summary + "|\n|      " + dotted_line + "\n"
        created_vms_summary = created_vms_summary + "|\tHostname: " + vmhostname + "\n" + vm_ssh_creds + "\n"
        if installer:
            accessUrl = get_access_url(vmip)
            # check if 'xcalar' option for --ldap option.  they'll log in with xcalar ldap.
            #If not, it still could be xcalar config options if they specified a curom ldapConfig file
            # so maybe at least print a note indicating
            login_details = "Login page credentials: "
            if ARGS.ldap == "xcalar":
                see_note_text_ldap = add_note("You can also log in with your Xcalar LDAP credentials; use '@xcalar.com' in the username")
                login_details += see_note_text_ldap
            #else:
                #omit the note for now since xcalar ldap will be default, dont want to confuse...
                #see_note_text = add_note("LOGIN PAGE: If you supplied a xcalar ldapConfig via --ldap, you will use your regular xcalar credentials on login page, with '@xcalar.com' as part of the username")
            login_details += "\n|\t " + LOGIN_UNAME + " / " + LOGIN_PWORD
            #login_details = LOGIN_UNAME + " / " + LOGIN_PWORD + " " + see_note_text

            login_data = "|\n|\tXD URL: " + accessUrl + "\n|\t" + login_details + "\n"
            created_vms_summary += login_data

    if installer:
        see_note_text = add_note("LICENSE KEY: This is a dev key and will not work on RC builds")
        created_vms_summary = created_vms_summary + "|\n| License key " + see_note_text + ": \n|\n" + LICENSE_KEY + "\n"

    clussumm = ""
    if cluster_name:
        clusternodedata = validate_cluster(vmips)
        debug_log("node data: " + str(clusternodedata))

        # get node 0 for access URL
        if not '0' in clusternodedata:
            raise ValueError("No '0' entry in cluster node data: {}".format(clusternodedata))
        node0ip = clusternodedata['0']
        accessUrl = get_access_url(node0ip)

        clussumm = "\n|\n=================== CLUSTER INFO ====================\n" \
            "|\n| Your VMs have been formed in to a cluster.\n" \
            "|\n| Cluster name: " + cluster_name  + "\n" \
            "| Access URL:\n|\t" + accessUrl + "\n" \
            "|\tLogin page Credentials: " + LOGIN_UNAME + " \ " + LOGIN_PWORD + "\n" \
            "|\n " + dotted_line + "\n"
        for nodenum in clusternodedata.keys():
            # get the name of the VM
            ip = clusternodedata[nodenum]
            vmhostname = get_hostname(ip)
            clussumm = clussumm + "|\n| Cluster Node" + nodenum + " is vm " + vmhostname + "]\n"
        clussumm = clussumm + "|\n " + dotted_line + "\n"
    created_vms_summary = created_vms_summary + clussumm

    if notes:
        created_vms_summary = created_vms_summary + "|\n" + solid_line + "\n" \
            "|\n|                  Notes              \n"
        for counter, note in enumerate(notes):
            created_vms_summary = created_vms_summary + "|\n| " + "*"*(counter+1) + " {}\n".format(note)

    created_vms_summary = created_vms_summary + "|\n" + solid_line

    return created_vms_summary

'''
    display a summary of work done
    (putting in own function right now so can deal with where to direct output... in here only
    once logging set up ill change
'''
def get_summary_string(vmids, ram, cores, ovirt_cluster, installer=None, cluster_name=None):

    summary_str = ""

    # vms were created
    if vmids:
        summary_str = summary_str + summary_str_created_vms(vmids, ram, cores, ovirt_cluster, installer=installer, cluster_name=cluster_name)

    # print debug on delete, shutdown, or powered on VMs with this job
    if ARGS.delete:
        if summary_str:
            summary_str += summary_str + "\n\n"
        summary_str = summary_str + solid_line + "\n" \
                        "|\n|  The following VMs were deleted:\n|"
        for deletedVm in ARGS.delete.split(','):
                    summary_str = summary_str + "\n|\t{}".format(deletedVm)
        summary_str = summary_str + "\n|\n" + solid_line

    if ARGS.shutdown:
        if summary_str:
            summary_str += "\n\n"
        summary_str = summary_str + solid_line + "\n" \
                        "|\n|  The following VMs have been shut down:\n|"
        for shutDownVm in ARGS.shutdown.split(','):
                    summary_str = summary_str + "\n|\t{}".format(shutDownVm)
        summary_str = summary_str + "\n|\n" + solid_line

    if ARGS.poweron:
        if summary_str:
            summary_str += "\n\n"
        summary_str = summary_str + solid_line + "\n" \
                        "|\n|  The following VMs are powered on:\n|"
        for poweredOnVm in ARGS.poweron.split(','):
                    summary_str = summary_str + "\n|\t{}".format(poweredOnVm)

        summary_str += "\n|\n" + solid_line

    # put strings around it for Jenkins to grep in the console log
    full_str = jenkins_summary_grep_start + "\n" + summary_str + "\n" + jenkins_summary_grep_stop

    return full_str

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

    debug_log("Extract cluster node data from {}  file on {}".format(DEFAULT_CFG_PATH, ip))

    status, stdout, stderr = run_ssh_cmd(ip, 'cat ' + DEFAULT_CFG_PATH)

    nodeips = {}

    # get num nodes in the cluster
    numnodes = None
    nodenumreg = re.compile('.*Node\.NumNodes=(\d+).*', re.DOTALL)
    matchres = nodenumreg.match(stdout)
    if matchres:
        debug_log("found match")
        numnodes = int(matchres.groups()[0])
    else:
        raise AttributeError("\nFound no entry for number of nodes in {} on {}\n".format(DEFAULT_CFG_PATH, ip))

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

'''
@uncompressed_license: (String) an uncompressed Xcalar license
@returns: (String) compressed version of the license
'''
def get_compressed_license(uncompressed_license):
    command ="echo '{}' | gzip -c - | base64 -w0".format(uncompressed_license)
    debug_log("Get compressed license with command: {}".format(command))
    output = run_system_cmd(command).strip()
    return output

'''
@compressed_license: (String) a compressed version of a Xcalar license
@returns: (String) uncompressed version of the license
'''
def get_uncompressed_license(compressed_license):
    command="echo '{}' | base64 -d | gunzip".format(compressed_license)
    debug_log("Get uncompressed license with command: {}".format(command))
    output = run_system_cmd(command).strip()
    return output

'''
Return an uncompressed Xcalar license.
If --license supplied (should be compressed), try to uncompress it, else,
look for XcalarLic.key (should be uncompressed) in script dir and use that.
validation is done by trying to compress then re-uncompress the data found.
'''
def get_validate_xcalar_uncompressed_license():

    # if no --license passed, the license file to look for
    license_to_look_for = SCRIPT_DIR + "/" + LICFILENAME

    arg_msg_reminder = "Did you pass a valid, COMPRESSED license value?"
    file_reminder = "Is {} a valid, UNCOMPRESSED Xcalar license?".format(license_to_look_for)

    # get a compressed license
    uncompressed_license_data_start = None
    if ARGS.license:
        try:
            uncompressed_license_data_start = get_uncompressed_license(ARGS.license)
        except Exception as e:
            raise ValueError("\n\nERROR: --license passed, but an error "
                "occured when trying to uncompress the "
                "license.\n{}\n".format(arg_msg_reminder))
    else:
        info_log("No --license passed... look for {} in ovirttool dir...".format(LICFILENAME))
        err_msg_start="ovirttol needs license data for VMs.  No --license " \
            "arg was passed so looking in script directory for a license file."
        if os.path.exists(license_to_look_for):
            # get license contents and compress
            try:
                with open(license_to_look_for, 'r') as lic_file:
                    uncompressed_license_data_start = lic_file.read()
            except Exception as e:
                raise ValueError("\n\nERROR: {}\n{} Was found, but an "
                    "error occured when trying to read the "
                    "file.\n{}\n".format(err_msg_start, license_to_look_for, file_reminder))
        else:
            raise ValueError("\n\nERROR: {}\n"
                "But {} does not exist. "
                "\nRe-run with --license=<compressed Xcalar license string>, or,\n"
                " copy the license file you want to use, into {}.\n"
                "Try this::\n\tcp $XLRDIR/src/data/XcalarLic.key {}"
                "\n".format(err_msg_start, license_to_look_for, SCRIPT_DIR, SCRIPT_DIR))

    # validate: try to compress, then uncompress found license data,
    # make sure result is same as start
    uncompressed_license_data_final = None
    err_msg_common_start = "License data was obtained, either " \
            "from --license arg, or, if it was not passed, by finding " \
            "a file {} in the script directory.".format(LICFILENAME)
    err_msg_common_end = "If you passed --license: {}\n" \
            "If you did not pass " \
            "--license: {}\n" \
            "Try re-running with --license=<valid, COMPRESSED, Xcalar " \
            "license>".format(arg_msg_reminder, file_reminder)
    try:
        uncompressed_license_data_start = uncompressed_license_data_start.strip()
        compressed_license = get_compressed_license(uncompressed_license_data_start)
        uncompressed_license_data_final = get_uncompressed_license(compressed_license)
    except Exception as e:
        raise ValueError("\n\nERROR: {}\n"
            "However, could not compressed and then uncompress "
            "the license data found, as a validation "
            "check.\n{}\n".format(err_msg_common_start, err_msg_common_end))
    # make sure they are equal
    if uncompressed_license_data_final and (uncompressed_license_data_final != uncompressed_license_data_start):
        raise ValueError("\n\nERROR: {}\n"
            "Tried to validate by compressing, "
            "then uncompressing the data, but the final uncompressed data "
            "did not match the initial uncompressed data.\n"
            "\nInitial uncompressed license data:\n{}\n"
            "\nFinal uncompressed license data (after compressing then "
            "uncompressing:\n\n{}\n{}\n".format(err_msg_common_start, uncompressed_license_data_start, uncompressed_license_data_final, err_msg_common_end))
    return uncompressed_license_data_final

'''
Return installer URL to use based on cmd args pasesd in.
Validate final result.
'''
def get_validate_installer_url():

    if ARGS.noinstaller:
        return None

    installer_header = 'http://'
    default_installer = installer_header + 'netstore/builds/byJob/BuildTrunk/xcalar-latest-installer-prod-match'

    installer_url_final = ARGS.installer or default_installer

    if installer_url_final.startswith(installer_header):
        # make sure they have given the regular RPM installer, not userinstaller
        filename = os.path.basename(installer_url_final)
        if 'gui' in filename or 'userinstaller' in filename:
            raise ValueError("\n\nERROR: Please supply the regular RPM " \
                "installer, not the gui installer or userinstaller\n")
    else:
        raise ValueError("\n\nERROR: --installer arg should be an URL for " \
            "an RPM installer, which you can curl.\n" \
            "(If you know the <path> to the installer on netstore, " \
            "then the URL to supply would be: " \
            "--installer=http://netstore.int.xcalar.com/<path on netstore>\n"
            "Example: --installer={})\n".format(default_installer))
    return installer_url_final

'''
Return ldap URL to use based on user supplied --ldap arg
'''
def get_validate_ldap_config_url():

    ldap_arg = ARGS.ldap

    # ldap URL returned should be a http:// URL.
    ldap_config_url = None
    # for --ldap arg, user can supply one of the keys of LDAP_CONFIGS,
    # or can supply an URL.
    if ldap_arg:
        if ldap_arg in LDAP_CONFIGS:
            ldap_config_url = LDAP_CONFIGS[ldap_arg]
        elif ldap_arg.startswith("http"):
            ldap_config_url = ldap_arg
        else:
            raise ValueError("\n\nERROR: --ldap not a valid type.  "
                "Valid values you can supply to --ldap: {}\n" \
                "Or, you can supply a curlable URL to your " \
                "own file\n".format(", ".join(LDAP_CONFIGS.keys())))
    else:
        # --ldap default should be one of the keys in LDAP_CONFIG
        # if no longer assigning a default, it needs to be
        # being assigned in this function or the run will probably fail
        raise RuntimeException("--ldap does not appear " \
            "to be taking a default anylonger.  Update script")
    return ldap_config_url

'''
Return puppet_role to use based on user supplied --puppet_arg;
if no arg supplied, set default based on if an install will be done.
'''
def get_validate_puppet_role():
    puppet_role = ARGS.puppet_role

    # install scenario: set default or ensure user supplied
    # jenkins_slave role!
    # note: not sufficient to check ARGS.installer to determine if installing;
    # use built-in function
    if will_install():
        if puppet_role is None:
            puppet_role = DEFAULT_PUPPET_ROLE_INSTALL
        # warn if puppet_role isn't jenkins_slave for install scenarios
        if puppet_role.lower() != DEFAULT_PUPPET_ROLE_INSTALL.lower():
            warn_log("\n\nYou are installing Xcalar, but puppet role " \
                " is set as {}!  This could cause conflicts with Caddy.\n" \
                "If not desired, re-run with another puppet role, " \
                "(--puppet_role option), or " \
                "--noinstaller option.\n".format(DEFAULT_PUPPET_ROLE_INSTALL))
    elif puppet_role is None:
        # set default for no install, and user didn't pass puppet_role
        puppet_role = DEFAULT_PUPPET_ROLE_NO_INSTALL

    return puppet_role

'''
Validates user params/combiantions.
Any illegal params/combinations results in ValueError Exception being thrown

Params with defaults based on other params/logic, or which
 require further modiciation or logic to be used, are validated in individual functions.
'''
def validate_params():

    # modification operations
    operations = [ARGS.count, ARGS.delete, ARGS.shutdown, ARGS.poweron]

    # if trying to list vms, let them know no other options will be done
    if ARGS.list:
        if any(operations):
            raise ValueError("\n\nERROR: --list will list all VMs, "
                "no other operations can be done.  It must be "
                "specified alone.\n")
    else:
        if ARGS.formatted or ARGS.verbose:
            raise ValueError("\n\nERROR: --verbose and --formatted are only " \
                "used when --list is specified (Display more data, and " \
                "pretty-print, respectively)\n")

    if ARGS.count:
        if ARGS.count > MAX_VMS_ALLOWED or ARGS.count <= 0:
            raise ValueError("\n\nERROR: --count argument must be an integer " \
                "between 1 and {}\n" \
                "(ovirttool will provision that number of new VMs " \
                "for you)".format(MAX_VMS_ALLOWED))

        if ARGS.listen and ARGS.count > 1 and not ARGS.nocluster:
            raise ValueError("\n\n--listen is only for single node cases; "
                "multi-node clusters will listen outside localhost by default\n")

        # validate the basename they gave for the cluster
        if not ARGS.vmbasename:
            errmsg = ""
            if ARGS.count == 1:
                errmsg = "\n\nPlease supply a name for your new VM using " \
                    "--vmbasename=<name>\n"
            else:
                errmsg = "\n\nPlease supply a basename for your requested " \
                    "VMs using --vmbasename=<basename>\n" \
                    "(The tool will name the new VMs as : " \
                    "<basename>-vm0, <basename>-vm1, .. etc\n"
            if not ARGS.nocluster:
                errmsg = errmsg + "The --vmbasename value will become the " \
                    "name of the created cluster, too.\n"
            raise ValueError(errmsg)
        else:
            # validate hostname is in an allowed format
            try:
                modules.OvirtUtils.validate_hostname(ARGS.vmbasename)
            except ValueError as e:
                raise ValueError("\n\nERROR: --vmbasename: {}\n".format(str(e)))

        if ARGS.ovirtcluster:
            # make sure they supplied a valid cluster with a template
            if ARGS.ovirtcluster not in OVIRT_TEMPLATE_MAPPING:
                raise ValueError("\n\nERROR: --ovirtcluster must be one of " \
                    "the following: {}\n" \
                    "(If '{}' is a valid cluster in Ovirt, " \
                    "probably there is no supported template for it " \
                    "yet in this tool)\n".format(", ".join(OVIRT_TEMPLATE_MAPPING.keys()), ARGS.ovirtcluster))

        if ARGS.noinstaller:
            if ARGS.installer:
                raise AttributeError("\n\nERROR: You have specified not to " \
                    "install xcalar with the --noinstaller option,\n"
                    "but also provided an installation path with the " \
                    "--installer option.\n"
                    "(Is this what you intended?)\n")
        else:
            # if you need to check conditions for if an install is being done,
            # do NOT check for ARGS.installer in this block to do that;
            # (--installer doesn't get an automatic default, so it might not be set
            # yet, even though an install will be done.)
            # if here : ARGS.count + ~ notinstaller --> an install is going to be done!
            # there is also a function 'will_install' which can be used.
            pass
    else:
        '''
            if not trying to create vms,
            make sure at least runing to remove VMs then, else nothing to do
        '''
        if not ARGS.delete and not ARGS.shutdown and not ARGS.poweron and not ARGS.list:
            raise AttributeError("\n\nERROR: Please re-run this script with " \
                "--count=<number of vms you want>\n")

'''
    validates lists of vms for param validation.
    :list_option_mapping: hash where key is name of the cmd arg for that list
        (so can include it in error msg), and value is the list to validate for that arg
'''
def validateVmLists(list_option_mapping):
    err_msg = ""
    for cmd_arg_name in list_option_mapping.keys():
        # validate list of VMs for that cmd arg
        invalid_identifiers = []
        for vm_identifier in list_option_mapping[cmd_arg_name]:
            if not find_vm_id_from_identifier(vm_identifier):
                invalid_identifiers.append(vm_identifier)
        if invalid_identifiers:
            err_msg = err_msg + "\nError on {}: " \
                "invalid VMs specified: {}".format(cmd_arg_name, ", ".join(invalid_identifiers))
    if err_msg:
        valid_vms = get_all_vms()
        err_msg = "{}\n{}\n\nPlease see list of valid vms above\n".format("\n\t".join(valid_vms), err_msg)
        raise ValueError(err_msg)

'''
Return True if a Xcalar install will be performed, based on user supplied args
and False if a Xcalar install will not be performed.
'''
def will_install():
    # note: not sufficient to check ARGS.installer to determine if installing;
    # install is done by default but no default given to --installer arg
    # due to how it's being error checked.
    # if --count > 0 and --noinstaller was NOT supplied, this is sufficient
    # to determine an install will be done.
    if ARGS.count and not ARGS.noinstaller:
        return True
    return False

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

:param_name: String to display in Error output in dupe case,
    indicating which param is having an issue
:param_value: the param the user supplied
'''
def get_multi_param_values(param_name, param_value, error_on_dupes=True):
    if not param_value:
        return []
    split_list = param_value.split(',')
    values = {}
    dupes = []
    for arg in split_list:
        if arg in values.keys():
            dupes.append(arg)
        else:
            values[arg] = ''
    if dupes and error_on_dupes:
        raise ValueError("\n\nERROR: Duplicate values were supplied " \
            "to {}: {}\n".format(param_name, ", ".join(dupes)))
    return list(values.keys())

'''
Generates a summary data file with information about the job.
File @ <script dir>/ovirttool_run.txt, unless specified by OVIRT_DATA_FILE env var
Intermediary dirs are created as needed.
'''
def generate_data_file(vms_created, vms_deleted, vms_shutdown, vms_powered_on):

    default_data_file = SCRIPT_DIR + "/ovirttool_run.txt"
    data_file_path = os.environ.get("OVIRT_DATA_FILE") or default_data_file

    file_str = ""
    file_str += "\ncmd args:"
    for cmd_arg in sys.argv:
        file_str += "\n" + cmd_arg

    file_str += "\n\ntags:"
    tags = get_multi_param_values("--tags", ARGS.tags)
    for tag in tags:
        file_str += "\n" + tag
    file_str += "\n\nCreated:"
    for vm in vms_created:
        file_str += "\n" + vm
    file_str += "\n\nDeleted:"
    for vm in vms_deleted:
        file_str += "\n" + vm
    file_str += "\n\nShutdown:"
    for vm in vms_shutdown:
        file_str += "\n" + vm
    file_str += "\n\nPowered-on:"
    for vm in vms_powered_on:
        file_str += "\n" + vm

    # write the output file; create intermediary dirs first if dont exist
    info_log("Create data file at {}".format(data_file_path))
    os.makedirs(os.path.dirname(data_file_path), exist_ok=True)
    with open(data_file_path, 'w') as ovirt_data_file:
        ovirt_data_file.write(file_str)

if __name__ == "__main__":

    '''
    Parse and validate cmd arguments
    '''
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--count", type=int, default=0,
        help="Number of VMs you'd like to create")
    parser.add_argument("-l", "--list", action='store_true',
        help="List current VMs on Ovirt")
    parser.add_argument("--verbose", action='store_true',
        help="Display additional data per VM when using --list : hostname, ip, status (Takes longer)")
    parser.add_argument("--formatted", action='store_true',
        help="Format/pretty-print the --list data")
    parser.add_argument("--vmbasename", type=str,
        help="Basename to use for naming the new VM(s) (If creating a single VM, will name VMBASENAME, if multiple, will name them VMBASENAME-vm0, VMBASENAME-vm1, .., VMBASENAME-vm(n-1) )")
    parser.add_argument("--cores", type=int, default=DEFAULT_CORES,
        help="Number of cores per VM. (Defaults to {} cores)".format(DEFAULT_CORES))
    parser.add_argument("--ram", type=int, default=DEFAULT_RAM,
        help="RAM on VM(s) (in GB).  (Defaults to {})".format(DEFAULT_RAM))
    parser.add_argument("--nocluster", action='store_true',
        help="Do not create a Xcalar cluster of the new VMs.")
    parser.add_argument("--installer", type=str, #default='builds/Release/xcalar-latest-installer-prod',
        help="URL to RPM installer to use for installing Xcalar on your VMs.  (Should be an RPM installer you can curl, example: http://netstore/<netstore's path to the installer>). \nIf not supplied, will use RPM installer for most recent prod version of BuildTrunk without version mismatch.)")
    parser.add_argument("--noinstaller", action="store_true", default=False,
        help="Don't install Xcalar on provisioned VM(s)")
    parser.add_argument("--ovirtcluster", type=str, default=DEFAULT_OVIRT_CLUSTER,
        help="Which ovirt cluster to create the VM(s) on.  (Defaults to {})".format(DEFAULT_OVIRT_CLUSTER))
    parser.add_argument("--tryotherclusters", action="store_true", default=False,
        help="If supplied, then if unable to create the VM on the given Ovirt cluster, will try other clusters on Ovirt before giving up")
    parser.add_argument("--tags", type=str,
        help="Useful data tags for this run of ovirttool. For example, a username or a purpose description. Multiple tags can be specified with commas. NO WHITESPACES, even if quoted. (tags will be included in datafile output when tool concludes; this is mostly for automation/bookkeeping.  Please use to help keep track of VM purposes.)")
    parser.add_argument("--license", type=str,
        help="A compressed Xcalar license String. (If not supplied, will look in {} for {}.)".format(SCRIPT_DIR, LICFILENAME))
    parser.add_argument("--puppet_role", type=str,
        help="Role the VM(s) should have (Defaults to {} if Xcalar is installed, and {} for no install)".format(DEFAULT_PUPPET_ROLE_INSTALL, DEFAULT_PUPPET_ROLE_NO_INSTALL))
    parser.add_argument("--puppet_cluster", type=str,
        help="Puppet cluster to enable")
    parser.add_argument("--delete", type=str,
        help="Single VM or comma separated String of VMs you want to remove from Ovirt (could be, IP, VM name, etc).")
    parser.add_argument("--shutdown", type=str,
        help="Single VM or comma separated String of VMs you want to shut down (could be, IP, VM name, etc).  This will help free up resources while your VM is not in use.")
    parser.add_argument("--poweron", type=str,
        help="Single VM or comma separated String of VMs to power on")
    parser.add_argument("--ldap", type=str, default='xcalar', # will get filepath from LDAP_CONFIGS hash
        help="Type of ldapConfig to use if Xcalar is being installed ({}), or, path to an URL you can curl, to a custom ldapConfig.json file".format(", ".join(LDAP_CONFIGS.keys())))
    parser.add_argument("--listen", action='store_true',
        help="For single node clusters, sets Node.0.IpAddr in /etc/xcalar/default.cfg to VM's hostname; (Will be able to listen to incoming requests, but relies on Ovirt DNS to work properly)")
    parser.add_argument("--user", type=str,
        help="Your LDAP username (no '@xcalar.com')")
    parser.add_argument("-nr", "--norand", action="store_true", default=False,
        help="Don't add random chars to vmbasename; use vmbasename exactly. (Use only if you are certain this name has NEVER been used by any VM in Ovirt, even by past deleted VMs, else, you will encounter DNS issues.  Use at your OWN RISK!)")
    parser.add_argument("-f", "--force", action="store_true", default=False,
        help="Force certain operations such as provisioning, delete, when script would fail normally")

    ARGS = parser.parse_args()

    # validate user params.
    validate_params()

    # get params needed for this run, which have values based on user params.
    # (can't use from ARGS.<param> directly).
    puppet_role = get_validate_puppet_role() # default based on other params
    installer = get_validate_installer_url() # note: just because it has a value doesnt mean install is being done (will have value in ARGS.delete, etc. cases, only returns None if --noinstaller)
    ldap_config_url = get_validate_ldap_config_url()
    xcalar_license_uncompressed = get_validate_xcalar_uncompressed_license()
    FORCE = ARGS.force # used globally

    # script setup
    setup()

    #open connection to Ovirt server
    CONN = open_connection(user=ARGS.user)

    # if list requested, list all VMs and quit.
    if ARGS.list:
        valid_vms = get_all_vms(verbose=ARGS.verbose, formatted=ARGS.formatted)
        info_log("\n\n{}\n".format("\n".join(valid_vms)), timestamp=False)
        sys.exit(0)

    # validation that requires a connection to the Ovirt engine (validating VMs)
    #doing all validation before calling any of the operations so can fail out early
    vms_to_delete = get_multi_param_values("--delete", ARGS.delete) # errs on dupes
    vms_to_shutdown = get_multi_param_values("--shutdown", ARGS.shutdown)
    vms_to_poweron = get_multi_param_values("--poweron", ARGS.poweron)
    # validate all the VMs in these lists are valid
    # validating in one go because want to display list of valid vms
    # in err msg; don't want to repeat that list for each arg that could have invalid entries
    validateVmLists({"--delete": vms_to_delete, "--shutdown": vms_to_shutdown, "--poweron": vms_to_poweron})

    ## DO REQUESTED OPERATIONS ##

    '''
        remove vms first if requested, to free up resources
    '''
    if ARGS.delete and vms_to_delete: # to be on the safe side check both?
        remove_vms(vms_to_delete)

    '''
        shut down VMs if requsted, to free up resources
    '''
    if ARGS.shutdown and vms_to_shutdown:
        shutdown_vms(vms_to_shutdown)

    '''
        power up existing VMs if requested before creating new ones
    '''
    if ARGS.poweron and vms_to_poweron:
        power_on_vms(vms_to_poweron)

    ''''
        main driver
    '''

    #  spin up number of vms requested
    vmids = [] # unique ovirt ids for vms generated
    hostnames = [] # hostnames assigned to the vms generated
    ips = [] # ips assigned to generated vms
    cluster_name = None
    if ARGS.count:
        # generate names for the VMs.
        # generate_vm_names will take the basename you supply it,
        # genrate <another basename> from this with randomness (to avoid old hostnames being resued), then
        # create --count number of VM names from <another basename>.  It returns those Vm names,
        # and <another basename> (if creating cluster, will name the cluster <another basename>)
        unique_generated_basename, vmnames = generate_vm_names(ARGS.vmbasename, int(ARGS.count), no_rand=ARGS.norand)
        vmids = provision_vms(vmnames, ARGS.ovirtcluster, convert_mem_size(int(ARGS.ram)), int(ARGS.cores), tryotherclusters=ARGS.tryotherclusters) # user gives RAM in GB but provision VMs needs Bytes

        if not ARGS.noinstaller:
            # if you supply a value to 'createcluster' arg of setup_xcalar,
            # then once xcalar install compled on all nodes will form the vms in
            # to a cluster by that name
            if not ARGS.nocluster and int(ARGS.count) > 1:
                cluster_name = unique_generated_basename
            setup_xcalar(vmids, xcalar_license_uncompressed, installer, ldap_config_url, ARGS.listen, createcluster=cluster_name)

        # get hostnames to print to stdout, and ips for restart
        for vmid in vmids:
            next_ip = get_vm_ip(vmid)
            ips.append(next_ip)
            hostnames.append(get_hostname(next_ip))

    # get summary of work done, while VMs are still ssh'able by ovirttool
    summary_string = get_summary_string(vmids, int(ARGS.ram), int(ARGS.cores), ARGS.ovirtcluster, installer=installer, cluster_name=cluster_name)

    # setup puppet on all the VMs
    # you can not make any more root ssh calls to the VMs after this;
    # ssh'ing is done in this script with a special ovirt pub key
    # puppet will remove it from auth users.
    enable_puppet_on_vms_in_parallel(vmids, puppet_role, puppet_cluster=ARGS.puppet_cluster)

    # TEMPORARY: running puppet results in issue with ldapConfig which was set up.
    # need to restart xcalar service post-puppet install for ldap to take effect.
    if not ARGS.noinstaller:
        restart_xcalar_in_parallel(ips, restart_expserver=True)

    '''
        display a useful summary to user of work done
    '''
    # print hostnames of each created vm to stdout for other scripts to consume
    for hostname in hostnames:
        debug_log(hostname)
    info_log(summary_string, timestamp=False)

    # generate a data file with minimal info (for automation/log tracking)
    # (env var OVIRT_DATA_FILE can specify where the file is written)
    generate_data_file(hostnames, vms_to_delete, vms_to_shutdown, vms_to_poweron)

    # close connection
    close_connection(CONN)
