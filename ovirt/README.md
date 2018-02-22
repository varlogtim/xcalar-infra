SUMMARY:
This initial tool will provision a single VM
and bring it up as a single-node Xcalar cluster
with the most recent RC build.

Basic usage:

	python ovirttool.py --create_one_node_cluster

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

Run script:

	python ovirttool.py --create_one_node_cluster

Specify another cluster to build the vm on (defaults to node4-cluster)

	python ovirttool.py --create_one_node_cluster --homenode=node2-cluster

Supply your username to bypass script prompting you for username:

	python ovirttool.py --create_one_node_cluster --user=you

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


