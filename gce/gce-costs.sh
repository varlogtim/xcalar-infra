#!/bin/bash


TMPDIR="${TMPDIR:-/tmp}/$LOGNAME/gce"
mkdir -p $TMPDIR


gcloud compute instances list | grep RUNNING > "$TMPDIR/instances.txt"
gcloud compute disks list | tail -n+2 > "$TMPDIR/disks.txt"


pd_standard=$(grep pd-standard "$TMPDIR/disks.txt" | awk 'BEGIN{x=0}{x=x+$3}END{print x}')
pd_ssd=$(grep pd-ssd "$TMPDIR/disks.txt" | awk 'BEGIN{x=0}{x=x+$3}END{print x}')
g1_small="$(grep g1-small "$TMPDIR/instances.txt" | wc -l)"
n1_standard_1="$(grep n1-standard-1 "$TMPDIR/instances.txt" | wc -l)"
n1_standard_8="$(grep n1-standard-8 "$TMPDIR/instances.txt" | wc -l)"
n1_highmem_8="$(grep n1-highmem-8 "$TMPDIR/instances.txt" | wc -l)"
n1_highmem_16="$(grep n1-highmem-16 "$TMPDIR/instances.txt" | wc -l)"

# Hourly cost without sustained discount
names=(pd-standard "pd-ssd   " g1-small n1-standard-1 n1-standard-8 n1-highmem-8 n1-highmem-16)
count=($pd_standard $pd_ssd $g1_small $n1_standard_1 $n1_standard_8 $n1_highmem_8 $n1_highmem_16)
costs=(0.04 0.17 0.27 0.05 0.4 0.504 1.008)
scale=(1.0 1.0 720.0 720.0 720.0 720.0 720.0)
total=0.0
echo "Item			Count		Monthly"
for i in `seq 0 $(( ${#names[@]} - 1 ))`; do
    line="$(echo "${count[$i]}*${costs[$i]}*${scale[i]}" | bc)"
    total="$(echo $total + $line | bc)"
    echo "${names[$i]}		${count[$i]}		$line"
done

echo ""
echo "Total:    $total"
echo ""
