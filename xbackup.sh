#!/bin/bash

##############################################################
#                                                            #
# Bash script wrapper for creating, preparing and storing    #
#   XtraBackup based backups for MySQL.                      #
#                                                            #
# @author Jervin Real <jervin.real@percona.com>              #
#                                                            #
##############################################################

# What type of backup, 'full', 'incr'
BKP_TYPE=$1
# If type is incremental, and this options is specified, it will be used as 
#    incremental basedir instead.
INC_BSEDIR=$3
# Local options
WORK_DIR=/ssd/sb/xbackups
DATADIR=/ssd/sb/msb_5_0_91/data
CURDATE=$2
#CURDATE=$(date +%Y-%m-%d_%H_%M_%S)
LOG_FILE="${WORK_DIR}/${CURDATE}.log"
INF_FILE="${WORK_DIR}/${CURDATE}-info.log"

# How many backups do we want to keep remote and optionally local
STORE=1

# Will be used as --defaults-file for innobackupex if not empty
DEFAULTS_FILE=/ssd/sb/msb_5_0_91/my.sandbox.cnf
USE_MEMORY=1G

# If defined, backup information will be stored on database.
MY="/ssd/sb/msb_5_0_91/use percona"

##############################################################
#      Modifications not recommended beyond this point.      #
##############################################################

if [ -f /tmp/xbackup.lock ]; then echo "ERROR: Another backup is still running!" | tee $INF_FILE; exit 1; fi
touch /tmp/xbackup.lock

if [ ! -n "${BKP_TYPE}" ]; then echo "ERROR: No backup type specified!"; exit 1; fi
echo "Backup type: ${BKP_TYPE}" | tee -a $INF_FILE

_start_backup_date=`date`
echo "Backup job started: ${_start_backup_date}" | tee -a $INF_FILE

_day_of_wk=`date +%u`
#_day_of_wk=7

# Check for innobackupex
_ibx=`which innobackupex`
if [ "$?" -gt 0 ]; then echo "ERROR: Could not find innobackupex binary!"; exit 1; fi
if [ -n $DEFAULTS_FILE ]; then _ibx="${_ibx} --defaults-file=${DEFAULTS_FILE}"; fi

_ibx_bkp="${_ibx} --no-timestamp"

# Determine what will be our --incremental-basedir
if [ "${BKP_TYPE}" == "incr" ];
then
   if [ -n "${INC_BSEDIR}" ]; 
   then
      if [ ! -d ${WORK_DIR}/${INC_BSEDIR} ]; 
      then 
         echo "ERROR: Specified incremental basedir ${WORK_DIR}/${_inc_basedir} does not exist."; 
         exit 1; 
      fi

      _inc_basedir=$INC_BSEDIR
   else
      _sql=$(cat <<EOF
SELECT 
   DATE_FORMAT(started_at,'%Y-%m-%d_%H_%i_%s') 
FROM backups 
ORDER BY started_at DESC 
LIMIT 1
EOF
)
      echo
      echo "SQL: ${_sql}"
      echo
      _inc_basedir=$($MY -BNe "${_sql}")
   fi

   if [ ! -n "$_inc_basedir" ]; 
   then 
      echo "ERROR: No valid incremental basedir found!"; 
      exit 1; 
   fi

   if [ ! -d "${WORK_DIR}/${_inc_basedir}" ]; 
   then 
      echo "ERROR: Incremental basedir ${WORK_DIR}/${_inc_basedir} does not exist."; 
      exit 1; 
   fi

   _ibx_bkp="${_ibx_bkp} --incremental ${WORK_DIR}/${CURDATE} --incremental-basedir  ${WORK_DIR}/${_inc_basedir}"
   _week_no=$($MY -BNe "SELECT DATE_FORMAT(STR_TO_DATE('${_inc_basedir}','%Y-%m-%d_%H_%i_%s'),'%U')")
   echo "Running incremental backup from basedir ${WORK_DIR}/${_inc_basedir}"
else
   _ibx_bkp="${_ibx_bkp} ${WORK_DIR}/${CURDATE}"
   _week_no=$($MY -BNe "SELECT DATE_FORMAT(STR_TO_DATE('${CURDATE}','%Y-%m-%d_%H_%i_%s'),'%U')")
   echo "Running full backup ${WORK_DIR}/${CURDATE}"
fi


# make sure we're root
#if [ `whoami` != 'root' ]; then echo "ERROR: `basename $0` must be run as user root"; exit 1; fi

# check for work directory
if [ ! -d ${WORK_DIR} ]; then echo "ERROR: XtraBackup work directory does not exist"; exit 1; fi

DATASIZE=`du --max-depth=0 $DATADIR|awk '{print $1}'`
DISKSPCE=`df $WORK_DIR|tail -n-1|awk '{print $(NF-2)}'`
HASSPACE=`echo "${DATASIZE} ${DISKSPCE}"|awk '{if($1 < $2) {print 1} else {print 0}}'`
NOSPACE=0

echo "Checking disk space ... (data: $DATASIZE) (disk: $DISKSPCE)"
if [ "$HASSPACE" -eq "$NOSPACE" ]; then echo "WARNING: Insufficient space on backup directory"; exit 1; fi

#TODAYBKUP=$(ls $WORK_DIR|egrep "^$CURDATE")
# check if we're not running second time today
#if [ "$?" -eq 0 ]; then  echo "ERROR: A backup for today ${WORK_DIR}/${TODAYBKUP} exists."; exit 1; fi

echo
echo "Xtrabackup started: `date`" | tee -a "${INF_FILE}"
echo

# Keep track if any errors happen
_status=0

#Llet's create the backup
cd $WORK_DIR
echo "Backing up with: $_ibx_bkp"
$_ibx_bkp
RETVAR=$?

_end_backup_date=`date`
echo 
echo "Xtrabackup finished: ${_end_backup_date}" | tee -a "${INF_FILE}"
echo

# Check the exit status from innobackupex, but dont exit right away if it failed
if [ "$RETVAR" -gt 0 ]; then 
   echo "ERROR: non-zero exit status of xtrabackup during backup. Something may have failed!"; 
   exit 1; 
fi

if [ -n "${USE_MEMORY}" ]; then _ibx_prep="$_ibx --use-memory=$USE_MEMORY"; fi
#THIS_BACKUP=$(ls -1 | egrep '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -nr | head -n1)
if [ "$status" != 1 ]; then
   _start_prepare_date=`date`
   echo "Apply log started: ${_start_prepare_date}" | tee -a "${INF_FILE}"

   if [ "${BKP_TYPE}" == "incr" ];
   then 
      # Determine the full backup based on the given incremental base dir and current week number.
      _sql=$(cat <<EOF
SELECT 
   DATE_FORMAT(started_at,'%Y-%m-%d_%H_%i_%s'), id 
FROM backups 
WHERE type = 'full' AND 
   weekno = ${_week_no}
ORDER BY started_at DESC
LIMIT 1
EOF
)
      echo
      echo "SQL: ${_sql}"
      echo
      set -- $($MY -BNe "${_sql}")
      _incr_base=$1
      _incr_baseid=$2

      if [ ! -n "$_incr_base" ];
      then
         echo "ERROR: No valid base backup found!";
         exit 1;
      fi 

      if [ ! -d "${WORK_DIR}/${_incr_base}" ];
      then
         echo "ERROR: Base backup ${WORK_DIR}/${_incr_base} does not exist.";
         exit 1;
      fi
      _ibx_prep="${_ibx_prep} --apply-log ${WORK_DIR}/${_incr_base} --incremental-dir  ${WORK_DIR}/${CURDATE}"
      echo "Preparing incremental backup with ${_ibx_prep}"
   else
      _incr_baseid=0
      _ibx_prep="${_ibx_prep} --apply-log --redo-only ${WORK_DIR}/${CURDATE}"
      echo "Preparing base backup with ${_ibx_prep}"
   fi

   $_ibx_prep
   RETVAR=$?
fi

_end_prepare_date=`date`
echo
echo "Apply log finished: ${_end_prepare_date}" | tee -a "${INF_FILE}"
echo

# Check the exit status from innobackupex, but dont exit right away if it failed
if [ "$RETVAR" -gt 0 ]; then
   echo "ERROR: non-zero exit status of xtrabackup during --apply-log. Something may have failed! Please prepare, I have not deleted the new backup directory.";
   exit 1;
fi

_started_at=`date -d "${CURDATE}" "+%Y-%m-%d %H:%M:%S"`
_ends_at=`date -d "${_end_prepare_date}" "+%Y-%m-%d %H:%M:%S"`
_bu_size=`du -h --max-depth=0 ${WORK_DIR}/${CURDATE}|awk '{print $1}'`
_du_left=`df -h $WORK_DIR|tail -n-1|awk '{print $3}'`

_sql=$(cat <<EOF
INSERT INTO backups 
   (started_at, ends_at, size, path, 
   type, incrbase, weekno, baseid) 
VALUES('${_started_at}','${_ends_at}',
   '${_bu_size}','${WORK_DIR}/${CURDATE}',
   '${BKP_TYPE}','${_inc_basedir}', 
   ${_week_no}, ${_incr_baseid})
EOF
)
echo
echo "SQL: ${_sql}"
echo

if [ -n "$MY" ]; then $MY -e "${_sql}"; fi

echo "Cleaning up previous backup files:"
# Depending on how many sets to keep, we query the backups table.
# Find the ids of base backups first.
_prune_base=$($MY -BNe "SELECT GROUP_CONCAT(id SEPARATOR ',') FROM (SELECT id FROM backups WHERE type = 'full' ORDER BY started_at DESC LIMIT ${STORE},999999) t")
if [ -n "$_prune_base" ]; then
   _sql=$(cat <<EOF
SELECT 
   CONCAT(GROUP_CONCAT(DATE_FORMAT(started_at,'%Y-%m-%d_%H_%i_%s') SEPARATOR '* '),'*') 
FROM backups 
WHERE id IN (${_prune_base}) OR 
   baseid IN (${_prune_base}) 
ORDER BY id
EOF
)
   echo
   echo "SQL: ${_sql}"
   echo
   _prune_list=$($MY -BNe "${_sql}")
   if [ -n "$_prune_list" ]; then
      echo "Deleting backups: ${_prune_list}"
      _sql=$(cat <<EOF
DELETE FROM backups 
WHERE id IN (${_prune_base}) OR 
   baseid IN (${_prune_base})
EOF
)
      echo
      echo "SQL: ${_sql}"
      echo
      cd $WORK_DIR && rm -rf $_prune_list && $MY -e "${_sql}"
   fi
fi
echo " ... done"
echo

echo "Backup size: ${_bu_size}" | tee -a "${INF_FILE}"
echo "Remaining space on backup on device: ${_du_left}" | tee -a "${INF_FILE}"
echo "Logfile: ${LOG_FILE}" | tee -a "${INF_FILE}"
echo

rm -rf /tmp/xbackup.lock

exit 0
