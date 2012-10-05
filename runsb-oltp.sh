#!/bin/bash

HOME=/home/revin
PATH=$PATH:$HOME/bin
PERL5LIB=$HOME/share/perl5
SANDBOX_HOME=/ssd/msb
SANDBOX_BINARY=/wok/bin/mysql

export PATH=$PATH
export PERL5LIB=$PERL5LIB
export SANDBOX_HOME=$SANDBOX_HOME
export SANDBOX_BINARY=$SANDBOX_BINARY
export SANDBOX_AS_ROOT=1

MKSB=$(cat <<EOF
make_sandbox $7 -- \
   --no_confirm --no_show \
   --my_clause innodb_buffer_pool_size=8G \
   --my_clause innodb_file_per_table \
   --my_clause innodb_flush_method=O_DIRECT \
   --my_clause innodb_log_file_size=1G
EOF
)

SBDIR=$8
SBNME=$9

RMSB="sbtool -o delete --source_dir /ssd/msb/$SBDIR"

CWD=`pwd`
RNTIME=$1
TBLSZE=$2
TBLCNT=$3
THREADS=$4
SOCKET=$5
TSTMDE=$6
# Where is the mount point
MOUNT=/ssd
# Where is the device partition
PART=/dev/sde1
SB=/home/revin/bzr/sysbench/sysbench/sysbench
SBT=/home/revin/bzr/sysbench/sysbench/tests

> $CWD/$SBNME-runsb-oltp.log

function _s() {
   date +"TS %s.%N %F %T : $1" | tee -a $CWD/$SBNME-runsb-oltp.log
}

function _run() {
   _s "Start sb prepare"
   $SB --test=$SBT/db/parallel_prepare.lua \
      --oltp-table-size=$TBLSZE --oltp-tables-count=$TBLCNT \
      --num-threads=$THREADS --mysql-db=test \
      --mysql-user=msandbox --mysql-password=msandbox \
      --mysql-socket=/tmp/mysql_sandbox$SOCKET.sock \
      --report-interval=10 run 
   _s "End sb prepare"

   _s "Running SELECT"
#   ( php $CWD/run-select.php ) &
   ( echo "BEGIN; SELECT * FROM sbtest1 LIMIT 10; SELECT SLEEP(3600); ROLLBACK;" | /ssd/msb/$SBDIR/use test > /dev/null ) &

   _s "Start run-oltp-$TSTMDE-$TBLSZE-$THREADS"
   ( (
      $SB --test=$SBT/db/oltp.lua \
      --oltp-table-size=$TBLSZE \
      --oltp-test-mode=$TSTMDE --oltp-tables-count=$TBLCNT \
      --oltp-nontrx-mode=insert --max-requests=0 \
      --max-time=$RNTIME --num-threads=$THREADS --mysql-db=test \
      --mysql-user=msandbox --mysql-password=msandbox \
      --mysql-socket=/tmp/mysql_sandbox$SOCKET.sock \
      --report-interval=10 run) | \
   tee $CWD/$SBNME-runsb-oltp-$TSTMDE-$TBLSZE-$THREADS.txt ) &

   > $CWD/$SBNME-runsb-oltp-histlen.txt
   (
   while true; do
      /ssd/msb/$SBDIR/use -e "SHOW ENGINE INNODB STATUS \G"|grep 'History list' >> $CWD/$SBNME-runsb-oltp-histlen.txt && \
      sleep 10;
   done) &
   ISPID=$!

   sleep $RNTIME
   _s "End run-$TSTMDE-$TBLSZE-$THREADS"
}

_s "Benchmark started"
> $CWD/$SBNME-runsb-oltp-ds.txt
(
while true; do 
   date +"TS %s.%N %F %T" >> $CWD/$SBNME-runsb-oltp-ds.txt && \
   cat /proc/diskstats >> $CWD/$SBNME-runsb-oltp-ds.txt && \
   sleep 5;
done) &
DSPID=$!

_s "Start format ${sz}"
umount $MOUNT
if [ $? -ne 0 ]; then _s "ERROR: ${MOUNT} is in use!"; kill $DSPID; kill $ISPID; exit 1; fi
mkfs.xfs -fd su=64k,sw=2 $PART
mount $PART $MOUNT -o noatime,nobarrier,nodiratime
cd $MOUNT
sync
_s "End format ${sz}"

_s "Creating $SANDBOX_HOME"
mkdir -p $SANDBOX_HOME
_s "Creating sandbox server "
_s "$MKSB"
$MKSB
_run
_s "Cleaning up sandbox server"
$RMSB

cd $CWD

_s "Benchmark ended"

# Cleanup before we exit
cd $CWD
umount $MOUNT
mkfs.xfs -fd su=64k,sw=2 $PART
mount $PART $MOUNT -o noatime,nobarrier,nodiratime
kill $DSPID
kill $ISPID

_s "Script ended"

