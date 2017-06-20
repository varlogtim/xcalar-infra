#!/bin/bash

NODES="node1 node2 node3 node4 functest-el7-1 functest-el7-2 functest-el7-3"

echo "We have potentially found some core files on one or more of $NODES"

CORE_DIR=/freenas/qa/auto

coreexit=0
luser=
NEWCORES=
CORES=


_ssh () {
    ssh -t -T -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no $luser@$n "$@"
}

set +e
for n in $NODES; do

   if [[ $n == node* ]]; then
      luser=xcalar
   else
      luser=jenkins
   fi

   cores="$(_ssh "find / /cores -name 'core.*.*'  -maxdepth 1 2>/dev/null | grep 'core' | egrep '\.[0-9]+$'")"
   if [ $? -ne 0 ] || [ -z "$cores" ]; then
       echo "=== No cores on $n ==="
       continue
   fi

   echo "=== Cores for $n ==="
   for c in $cores; do
      echo $c
      b=`basename $c`
      THIS_CORE_DIR=$CORE_DIR/$b/$n
      if ! _ssh "ls -1dt $THIS_CORE_DIR 2>/dev/null"; then
         _ssh "mkdir -p $THIS_CORE_DIR"
         _ssh "cd $THIS_CORE_DIR && journalctl --no-pager > Xcalar.log && tar -cvSzf Xcalar.log.tgz Xcalar.log && rm -f Xcalar.log"
         _ssh "md5sum /opt/xcalar/bin/usrnode > $THIS_CORE_DIR/md5sum.txt"
         _ssh "cp /opt/xcalar/bin/usrnode $THIS_CORE_DIR"
         _ssh "ps -ef > $THIS_CORE_DIR/ps_output.txt"
         _ssh "yum list | grep -i xcalar > $THIS_CORE_DIR/yum_list.txt"
         _ssh "sudo tar -cvSzf $THIS_CORE_DIR/$b.tgz $c"
         _ssh "cp /etc/xcalar/default.cfg $THIS_CORE_DIR"
         NEWCORES=$NEWCORES$'\n'${THIS_CORE_DIR}/$b.tgz
         coreexit=1
      fi
   done
done

if [ "$coreexit" -eq "1" ]; then
   echo "NEW CORES FOUND LISTED BELOW:"
   echo $NEWCORES
else
   echo "NO NEW CORES FOUND"
fi

exit $coreexit
