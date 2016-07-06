#!/bin/bash


TMPDIR="${TMPDIR:-/tmp}/$LOGNAME/gce"
mkdir -p $TMPDIR


gcloud compute disks list | tail -n+2 > "$TMPDIR/disks.txt"
gcloud compute instances list > "$TMPDIR/gce.txt"
cat "$TMPDIR/gce.txt" | grep RUNNING | grep -v 'true' > "$TMPDIR/instances.txt"
cat "$TMPDIR/gce.txt" | grep RUNNING | grep 'true' > "$TMPDIR/instances_pe.txt"


pd_standard=$(grep pd-standard "$TMPDIR/disks.txt" | awk 'BEGIN{x=0}{x=x+$3}END{print x}')
pd_ssd=$(grep pd-ssd "$TMPDIR/disks.txt" | awk 'BEGIN{x=0}{x=x+$3}END{print x}')
g1_small="$(grep g1-small "$TMPDIR/instances.txt" | wc -l)"
n1_standard_1="$(grep n1-standard-1 "$TMPDIR/instances.txt" | wc -l)"
n1_standard_4="$(grep n1-standard-4 "$TMPDIR/instances.txt" | wc -l)"
n1_standard_4pe="$(grep n1-standard-4 "$TMPDIR/instances_pe.txt" | wc -l)"
n1_standard_8="$(grep n1-standard-8 "$TMPDIR/instances.txt" | wc -l)"
n1_standard_8pe="$(grep n1-standard-8 "$TMPDIR/instances_pe.txt" | wc -l)"
n1_highmem_8="$(grep n1-highmem-8 "$TMPDIR/instances.txt" | wc -l)"
n1_highmem_8pe="$(grep n1-highmem-8 "$TMPDIR/instances_pe.txt" | wc -l)"
n1_highmem_16="$(grep n1-highmem-16 "$TMPDIR/instances.txt" | wc -l)"
n1_highmem_16pe="$(grep n1-highmem-16 "$TMPDIR/instances_pe.txt" | wc -l)"

# Hourly cost without sustained discount
names=(pd-standard "pd-ssd   " g1-small n1-standard-1 n1-standard-4 n1-standard-4pe n1-standard-8 n1-standard-8pe n1-highmem-8 n1-highmem-8pe n1-highmem-16 n1-highmem-16pe)
count=($pd_standard $pd_ssd $g1_small $n1_standard_1 $n1_standard_4 $n1_standard_4pe $n1_standard_8 $n1_standard_8pe $n1_highmem_8 $n1_highmem_8pe $n1_highmem_16 $n1_highmem_16pe)
costs=(0.04 0.17 0.027 0.05 0.20  0.06 0.40 0.12 0.504 0.140 1.008 0.280)
scale=(1.00 1.00 720.0 720.0 720.0 720.0 720.0 720.0 720.0 720.0 720.0 720.0)
total=0.0
echo "Item				Count			Monthly"
for i in `seq 0 $(( ${#names[@]} - 1 ))`; do
    line="$(echo "${count[$i]}*${costs[$i]}*${scale[i]}" | bc)"
    if [[ "$line" = "0" ]]; then
        : #continue
    fi
    total="$(echo $total + $line | bc)"
    echo "${names[$i]}			${count[$i]}			$line"
done

echo ""
echo "Total:    $total"
echo ""
