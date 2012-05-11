#!/bin/bash

CWD=`pwd`
RMTIME=600
WMTIME=3600
RTESTS='seqrd rndrd'
WTESTS='seqwr rndwr rndrw'
SIZES='40 80'
THREADS='8 16 32'
# Where is the mount point
MOUNT=/ssd
# Where is the device partition
PART=/dev/sde1
SB=/home/revin/bin/sysbench

function _s() {
   date +"TS %s.%N %F %T : $1" | tee -a $CWD/runsb.log
}

function _run() {
   _s "Start sb prepare"
   # Prepare does not actuall do anything on teh second run
   # as if the files are still there, it will be reused.
   $SB --test=fileio --file-num=64 --file-total-size=${1}G prepare
   _s "End sb prepare"
   _s "Start run-${2}-${1}G-${4}"
   ($SB --test=fileio --file-total-size=${1}G \
      --file-test-mode=${2} --max-time=${3} \
      --max-requests=0 --num-threads=${4} \
      --rand-init=on --file-num=64 \
      --file-extra-flags=direct --file-fsync-freq=0 \
      --file-block-size=16384 --report-interval=10 run) | \
   tee $CWD/run-${2}-${1}G-${4}.txt
   _s "End run-${2}-${1}G-${4}"
}

_s "Benchmark started"

(
while true; do 
   date +"TS %s.%N %F %T" >> $CWD/runsb-ds.txt && 
   cat /proc/diskstats >> $CWD/runsb-ds.txt && 
   sleep 5;
done) &
DSPID=$!

for sz in $SIZES
do
   _s "Start format ${sz}"
   umount $MOUNT
   if [ $? -ne 0 ]; then _s "ERROR: ${MOUNT} is in use!"; kill $DSPID; exit 1; fi
   mkfs.xfs -fd su=64k,sw=2 $PART
   mount $PART $MOUNT -o noatime,nobarrier,nodiratime
   cd $MOUNT
   sync
   _s "End format ${sz}"

   for th in $THREADS
   do
      for tt in $RTESTS
      do
         _run $sz $tt $RMTIME $th
      # RTESTS
      done

      for tt in $WTESTS
      do
         _run $sz $tt $WMTIME $th
      # WTESTS
      done
   # THREADS
   done

   cd $CWD
# SIZES
done

_s "Benchmark ended"

# Cleanup before we exit
cd $CWD
umount $MOUNT
mkfs.xfs -fd su=64k,sw=2 $PART
mount $PART $MOUNT -o noatime,nobarrier,nodiratime
kill $DSPID

_s "Script ended"

