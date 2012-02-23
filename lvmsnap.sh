#!/bin/bash

# How many snapshots to keep
SNAPCNT=4
# Default sizes of snapshots
SNAPSZE=5G
# Volume group containing MySQL data
MYSQLVG=sb
# MySQL logical volume name
MYSQLLV=mysql-data
# MYSQL data directory mount point
MYSQLDD=/mysql/data
# Temporary file
TMPFILE=/tmp/lvmsnap-$$.tmp
# Binary logs directory
BLOGDIR=/mysql/logs
# Commands are snapshot, merge, list
CMD=$1
RESTRSNAP=$2

function trim {
  echo 'Trimming excess snapshots .. '
  lvs --noheadings -o lv_path|grep 'sb/mysql-data-'|head -n-4|awk '{print $1}'|xargs lvremove -f 
  ls $BLOGDIR|grep 'mysql-data-'|head -n-4|xargs rm -rf 
  echo 'done'
  echo
  lvs
  echo
}

function snap {
  echo 'Taking a new snapshot .. '
  snap="$MYSQLLV-`date +%Y%m%d%H%M`"
  mysql <<EOD 
FLUSH TABLES WITH READ LOCK;
\! mysql -e 'SHOW MASTER STATUS' > $BLOGDIR/${snap}-binlog-info
\! lvcreate --size=$SNAPSZE --snapshot --name $snap /dev/${MYSQLVG}/${MYSQLLV} > /dev/null 2>&1
UNLOCK TABLES;
EOD
  echo 'done'
  echo
  trim
}

function restore {
  if [ -z $RESTRSNAP ]; then
    echo 'Invalid snapshot requested.'
    echo
    exit 1
  fi


  rstr=$(lvs --noheadings -o lv_path|grep "sb/${MYSQLLV}-${RESTRSNAP}")
  if [ -z $rstr ]; then
    echo 'Snapshot not found!'
    echo
    exit 1
  fi

  # Shutdown MySQL
  echo 'Shutting down MYSQL ..'
  mysqladmin shutdown
  # Sleep some 120 seconds to let MySQL shutdown
  sleep 10
  kltmout=110
  while [ $kltmout -gt 0 ]; do
    RESPONSE=$(mysqladmin ping 2>&1)
    echo "$RESPONSE" | grep 'failed' 2>&1 && break
    sleep 1
    let kltmout=${kltmout}-1
  done
  if [ $kltmout -eq 0 ]; then
    echo "Timeout error occurred trying to shutdown MySQL."
    exit 1
  fi
  
  umount $MYSQLDD
  lvconvert --merge $rstr
  mount $MYSQLDD
  service mysql start
  echo "${rstr} successfully restored!"
  echo
}

case $CMD in
  'snapshot')
    snap;;
  'restore')
    restore;;
esac
