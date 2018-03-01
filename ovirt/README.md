Overview:

This tool will provision VMs on Ovirt.
Additionally, it can install Xcalar for you on the VMs,
and form them in to a Xcalar cluster.
You can customize the memory and cores on the VMs,
as well as which xcalar installation to use.

Basic Examples:

    ./ovirttool.sh --vms=4                   # create 4 VMs with latest RC build
    ./ovirttool.sh --vms=4 --createcluster   # create 4 VMs and form into Xcalar cluster
    ./ovirttool.sh --vms=4 --noxcalar        # create 4 VMs only; no xcalar install

-----------------------------------------------------

Setup:

(1) Required libraries (one time install)

    pip install ovirt-engine-sdk-python

(2) Xcalar License Files

Copy the latest license files from the xcalar repo,
in to the directory you will execute this script from
(cmd below assumes you have $XLRDIR env variable set)

    cp $XLRDIR/src/data/EcdsaPub.key .
    cp $XLRDIR/src/data/XcalarLic.key .

Alternatively, if you have the lic keys somewhere local on
your machine, you can always specify their paths directly
when you invoke the script:

    --pubsfile=<filepath to EcdsaPub.key>
    --licfile=<filepath to XcalarLic.key>

----------------------------------------------------

Help Menu:

    ./ovirttool.sh --help

----------------------------------------------------

More Examples:

Create a 4 node cluster from VMs on node4-cluster, with the latest RC build

    ./ovirttool.sh --vms=4 --createcluster

Create a 4 node cluster, but make VMs on node2-cluster (node4-cluster is default)

    ./ovirttool.sh --vms=3 --homenode=node2-cluster --createcluster

Create a 4 node cluster, with VMs having 8GB memory and 2 cores each

    ./ovirttool.sh --vms=4 --createcluster --ram=8 --cores=2

Create a 4 node cluster, but use an installer from a BuildCustom job on Jenkins
(the --installer arg to specify must be a path on Netstore to an RPM installer)

    ./ovrittool.sh --vms=4 --createcluster --installer=builds/byJob/BuildCustom/10384/prod/xcalar-1.3.0-10384-installer

Create just a single VM with the latest RC build

    ./ovirttool.sh --vms=1

Create 2 single VMs with latest RC build, and do not make them in to a cluster after install

    ./ovirttool.sh --vms=2

Create 2 single VMs but don't install Xcalar on them

    ./ovirttool.sh --vms=2 --noxcalar

To save time, you can supply your username when you call the script, to bypass script prompting you for this information

    ./ovirttool.sh --user=you <other args>

----------------------------------------------

Delete VMs:::

This tool can also delete VMs from Ovirt.  To delete VMs you
no longer need, supply the name or IP of the VM you'd like to
remove, or a comma sep list of such values.  Please be careful.

Delete VM with IP 10.10.2.88, as well as VM with name ovirt-vm-auto-105

    ./ovirttool.sh --delete=10.10.2.88,ovirt-vm-auto-105

You can provision new VMs and delete existing ones, in the same run.
(The tool will always handle the deletions first, to free up resources.)

Delete VM with IP 10.10.2.89, and then create a 2 node cluster

    ./ovirttool.sh --vms=2 --createcluster --delete=10.10.2.89

----------------------------------------------

[[
    VM specs::
    Operating System: Red Hat Enterprise Linux 7.x x64
]]


