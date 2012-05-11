#!/bin/bash

CWD=`pwd`
MAXTIME=3600
TESTS='seqwr seqrd rndrd rndwr rndrw'
SIZES='5 10'
THREADS='8 16'
# Where is the mount point
MOUNT=/ssd
# Where is the device partition
PART=/dev/sde1
SB=/home/revin/bin/sysbench

for tt in $TESTS
do
for th in $THREADS
do
   for sz in $SIZES
   do
      umount $MOUNT
      mkfs.xfs -fd su=64k,sw=4 $PART
      mount $PART $MOUNT -o noatime,nobarrier,nodiratime
      cd $MOUNT
      $SB --test=fileio --file-num=64 --file-total-size=${sz}G prepare
      sync
      echo 3 > /proc/sys/vm/drop_caches
      $SB --test=fileio --file-total-size=${sz}G --file-test-mode=${tt} --max-time=${MAXTIME} --max-requests=0 --num-threads=${th} --rand-init=on --file-num=64 --file-extra-flags=direct --file-fsync-freq=0 --file-block-size=16384 --report-interval=10 run | tee $CWD/run-${tt}-${sz}G-${th}.txt
      cd $CWD
   done
done
done
