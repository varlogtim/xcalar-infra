SUMMARY:
This tool will provision n VMs on Ovirt,
and bring them up as a Xcalar cluster with the
most recent RC build.

Basic usage:

	python ovirttool.py --num_vms=4

----------------------------------------------------
This is the early stage of this tool.  In coming phase:
	- specify custom build to install on nodes
	- supply custom values for RAM, cores, etc.
-----------------------------------------------------

Setup:

	pip install ovirt-engine-sdk-python

Copy the latest license files from the xcalar repo,
in to the directory you will execute this script from
(cmd below assumes you have $XLRDIR env set)

	cp $XLRDIR/src/data/EcdsaPub.key .
	cp $XLRDIR/src/data/XcalarLic.key .

(Note: if you have these lic key files stored somewhere local on
your machine, you can bypass this step if you want, and specify the
filepaths directly when you invoke the script using options below:)
	--pubsfile=<path to EcdsaPub.key>
	--licfile=<path to XcalarLic.key>

----------------------------------------------------

Examples:

Create a 4 node cluster from VMs on node4-cluster, with the latest RC build

	python ovirttool.py --num_vms=4

Create a 4 node cluster, but make VMs on node2-cluster (node4-cluster is default)

	python ovirttool.py --num_vms=3 --homenode=node2-cluster

Create a single node with the latest RC build

	python ovirttool.py --num_vms=1

Create 2 single VMs with latest RC build, but do not make them in to a cluster

	python ovirttool.py --num_vms=2 --dont_create_cluster

Supply you username to bypass script prompting you for username:

	python ovirttool.py --num_vms=2 <other options> --user=you

To delete VMs created you no longer need, to free up resources::

	python ovirttool.py --remove_vm=<vm name>

	(Note: To delete a VM you just made -
		use the <vm name> that displays when script completes)

----------------------------------------------

[[
	VM specs::
	Defined Memory: 16384 MB
	Number of CPU Cores: 4 (2:1:2)
	Is Stateless: false
	Operating System: Red Hat Enterprise Linux 7.x x64
]]


