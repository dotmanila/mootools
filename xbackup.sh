#!/bin/bash

##############################################################
#                                                            #
# Bash script wrapper for creating, preparing and storing    #
#   XtraBackup based backups for MySQL.                      #
#                                                            #
# @author Jervin Real <jervin.real@percona.com>              #
#                                                            #
##############################################################

# set this only if you don't have the mysql and xtrabackup binaries in your PATH
# export PATH=/wok/bin/xtrabackup/2.0.0/bin:/opt/percona/server/bin:$PATH

# print usage info
usage()
{
cat<<EOF >&2
   usage: xbackup.sh -t <type> -ts timestamp -i incremental-basedir -b backup-dir -d datadir -l binlogdir
   Only <type> is mandatory, and it can be one of full or incr
   ts is a timestamp to mark the backup with. defaults to $(date +%Y-%m-%d_%H_%M_%S)
   incremental-basedir will be passed to innobackupex as --incremental-basedir, if present and type was incr
   datadir is mysql's datadir, needed if it can't be found on my.cnf or obtained from mysql
   binlogdir is the dir where mysql stores binlogs, needed if it can't be found on my.cnf or obtained from mysql
EOF

}

# we need at least on arg, the backup type
[ $# -lt 1 ] && {
usage
exit 1
}


# timestamp for the backup
CURDATE=$(date +%Y-%m-%d_%H_%M_%S)

# Type of backup, accepts 'full' or 'incr'
BKP_TYPE=
# If type is incremental, and this options is specified, it will be used as 
#    --incremental-basedir option for innobackupex.
INC_BSEDIR=inc_$CURDATE
# Base dir, this is where the backup will be initially saved.
WORK_DIR=/backup
# This is where the backups will be stored after verification. If this is empty
# backups will be stored within the WORK_DIR. This should already exist as we will
# not try to create one automatically for safety purpose. Within ths directory
# must exist a 'bkps' and 'bnlg' subdirectories. In absence of a final stor, backups
# and binlogs will be saved to WORK_DIR
STOR_DIR=

# If you want to ship the backups to a remote server, specify
# here the SSH username and password and the remote directory
# for the backups. Absence of neither disables remote shipping
# of backups
#RMTE_DIR=/ssd/sb/xbackups/rmte
#RMTE_SSH="revin@127.0.0.1"

# Where are the MySQL data and binlog directories
DATADIR=/var/lib/mysql/
BNLGDIR=/var/lib/mysql/

   usage: xbackup.sh -t <type> -s timestamp -i incremental-basedir -b backup-dir -d datadir -l binlogdir


while  getopts "t:s:i:b:d:l:" OPTION; do 
    case $OPTION in 
	t) 
	    BKP_TYPE=$OPTARG
	    ;;
	s)
	    CURDATE=$OPTARG
	    ;;
	i)
	    INC_BSEDIR=$OPTARG
	    ;;
	b)
	    WORK_DIR=$OPTARG
	    ;;
	d)
	    DATADIR=$OPTARG
	    ;;
	l)
	    BNLGDIR=$OPTARG
	    ;;
	?)
	usage
	exit 1
	;;
    esac
done


# log-bin filename format, used when rsyncing binary logs
BNLGFMT=mysql-bin


# Whether to keep a prepared copy, sueful for
# verification that the backup is good for use.
# Verification is done on a copy under WORK_DIR and an untouched
# copy is stored on STOR_DIR
APPLY_LOG=1

# Whether to compress backups within STOR_DIR
STOR_CMP=1

LOG_FILE="${WORK_DIR}/bkps/${CURDATE}.log"
INF_FILE="${WORK_DIR}/bkps/${CURDATE}-info.log"

# How many backup sets do you want to keep, these are the
# count of full backups plus their incrementals. 
# i.e. is you set 2, there will be 2 full backups + their
# incrementals
STORE=2

KEEP_LCL=0

# Will be used as --defaults-file for innobackupex if not empty
DEFAULTS_FILE=
# Used as --use-memory option for innobackupex when APPLY_LOG is
# enabled
USE_MEMORY=1G

# mysql client command line that will give access to the schema
# and table where backups information will be stored. See
# backup table structure below.
MY="mysql percona"

# How to flush logs, on versions < 5.5.3, the BINARY clause
# is not yet supported. Not used at the moment.
FLOGS="${MY} -BNe 'FLUSH BINARY LOGS'"

# Table definition where backup information will be stored.
TBL=$(cat <<EOF
CREATE TABLE backups (
  id int(10) unsigned NOT NULL auto_increment,
  started_at timestamp NOT NULL default CURRENT_TIMESTAMP on update CURRENT_TIMESTAMP,
  ends_at timestamp NOT NULL default '0000-00-00 00:00:00',
  size varchar(15) default NULL,
  path varchar(120) default NULL,
  type enum('full','incr') NOT NULL default 'full',
  incrbase timestamp NOT NULL default '0000-00-00 00:00:00',
  weekno tinyint(3) unsigned NOT NULL default '0',
  baseid int(10) unsigned NOT NULL default '0',
  PRIMARY KEY  (`id`)
) ENGINE=InnoDB;
EOF
)

##############################################################
#      Modifications not recommended beyond this point.      #
##############################################################

_df() {
   df -P -B 1K $1|tail -n-1|awk '{print $4}'
}

_df_h() {
   df -Ph $1|tail -n-1|awk '{print $4}'
}

_du_r() {
   du -B 1K --max-depth=0 $1|awk '{print $1}'
}

_du_h() {
   du -h --max-depth=0 $1|awk '{print $1}'
}

_s_inf() {
   echo $1 | tee -a $INF_FILE
}

_d_inf() {
   echo $1 | tee -a $INF_FILE
   exit 1
}

_sql_log() {
   echo '' > $LOG_FILE
}

_sql_prune_base() {
   _sql=$(cat <<EOF
   SELECT COALESCE(GROUP_CONCAT(id SEPARATOR ','),'') 
   FROM (
      SELECT id 
      FROM backups 
      WHERE type = 'full' 
      ORDER BY started_at DESC 
      LIMIT ${STORE},999999
   ) t
EOF
   )

   _sql_log $_sql
   $MY -BNe "${_sql}"
}

_sql_prune_list() {
   _sql=$(cat <<EOF
      SELECT 
         CONCAT(GROUP_CONCAT(DATE_FORMAT(started_at,'%Y-%m-%d_%H_%i_%s') SEPARATOR '* '),'*') 
      FROM backups 
      WHERE id IN (${1}) OR 
         baseid IN (${1}) 
      ORDER BY id
EOF
   )

   _sql_log $_sql
   $MY -BNe "${_sql}"
}

_sql_prune_rows() {
   _sql=$(cat <<EOF
   DELETE FROM backups 
   WHERE id IN (${1}) OR 
      baseid IN (${1})
EOF
   )

   _sql_log $_sql
   $MY -BNe "${_sql}"
}

_sql_last_backup() {
   _sql=$(cat <<EOF
   SELECT 
      DATE_FORMAT(started_at,'%Y-%m-%d_%H_%i_%s') 
   FROM backups 
   ORDER BY started_at DESC 
   LIMIT 1
EOF
   )

   _sql_log $_sql
   $MY -BNe "${_sql}"
}

_sql_first_backup_elapsed() {
   _sql=$(cat <<EOF
   SELECT 
      CEIL((UNIX_TIMESTAMP()-UNIX_TIMESTAMP(started_at))/60) AS elapsed  
   FROM backups 
   ORDER BY started_at ASC 
   LIMIT 1
EOF
   )

   _sql_log $_sql
   $MY -BNe "${_sql}"
}

_sql_save_bkp() {
   _sql=$(cat <<EOF
   INSERT INTO backups 
      (started_at, ends_at, size, path, 
      type, incrbase, weekno, baseid) 
   VALUES(${1},'${2}',
      '${3}','${4}',
      '${BKP_TYPE}',${5}, 
      ${6}, ${7})
EOF
   )

   _sql_log $_sql
   $MY -BNe "${_sql}"
}

_sql_incr_bsedir() {
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

   _sql_log $_sql
   $MY -BNe "${_sql}"
}

if [ -f /tmp/xbackup.lock ]; then 
   _d_inf "ERROR: Another backup is still running or a previous backup failed, please investigate!"; 
fi
touch /tmp/xbackup.lock

if [ ! -n "${BKP_TYPE}" ]; then _d_inf "ERROR: No backup type specified!"; fi
echo "Backup type: ${BKP_TYPE}" | tee -a $INF_FILE

_start_backup_date=`date`
echo "Backup job started: ${_start_backup_date}" | tee -a $INF_FILE

DEFAULTS_FILE_FLAG=
[ -n "$DEFAULTS_FILE" ] && DEFAULTS_FILE_FLAG="--defaults-file=${DEFAULTS_FILE}"
# Check for innobackupex
_ibx=`which innobackupex`
if [ "$?" -gt 0 ]; then _d_inf "ERROR: Could not find innobackupex binary!"; fi
if [ -n $DEFAULTS_FILE ]; then _ibx="${_ibx} ${DEFAULTS_FILE_FLAG}"; fi

_ibx_bkp="${_ibx} --no-timestamp"
_this_bkp="${WORK_DIR}/bkps/${CURDATE}"
_last_bkp=$(_sql_last_backup)

if [ -n "$STOR_DIR" ]; then _this_stor=$STOR_DIR
elif [ $KEEP_LCL -eq 1 ]; then _this_stor=$WORK_DIR
else _this_stor=''
fi

# Determine what will be our --incremental-basedir
if [ "${BKP_TYPE}" == "incr" ];
then
   if [ -n "${INC_BSEDIR}" ]; 
   then
      if [ ! -d ${WORK_DIR}/bkps/${INC_BSEDIR} ]; 
      then 
         _d_inf "ERROR: Specified incremental basedir ${WORK_DIR}/bkps/${_inc_basedir} does not exist."; 
      fi

      _inc_basedir=$INC_BSEDIR
   else
      _inc_basedir=$_last_bkp
   fi

   if [ ! -n "$_inc_basedir" ]; 
   then 
      _d_inf "ERROR: No valid incremental basedir found!"; 
   fi

   if [ ! -d "${WORK_DIR}/bkps/${_inc_basedir}" ]; 
   then 
      _d_inf "ERROR: Incremental basedir ${WORK_DIR}/bkps/${_inc_basedir} does not exist."; 
   fi

   _ibx_bkp="${_ibx_bkp} --incremental ${_this_bkp} --incremental-basedir  ${WORK_DIR}/bkps/${_inc_basedir}"
   _week_no=$($MY -BNe "SELECT DATE_FORMAT(STR_TO_DATE('${_inc_basedir}','%Y-%m-%d_%H_%i_%s'),'%U')")
   echo "Running incremental backup from basedir ${WORK_DIR}/bkps/${_inc_basedir}"
else
   _ibx_bkp="${_ibx_bkp} ${_this_bkp}"
   _week_no=$($MY -BNe "SELECT DATE_FORMAT(STR_TO_DATE('${CURDATE}','%Y-%m-%d_%H_%i_%s'),'%U')")
   echo "Running full backup ${_this_bkp}"
fi

# Check for work directory
if [ ! -d ${WORK_DIR} ]; then _d_inf "ERROR: XtraBackup work directory does not exist"; fi

DATASIZE=$(_du_r $DATADIR)
DISKSPCE=$(_df $WORK_DIR)
HASSPACE=`echo "${DATASIZE} ${DISKSPCE}"|awk '{if($1 < $2) {print 1} else {print 0}}'`
NOSPACE=0

echo "Checking disk space ... (data: $DATASIZE) (disk: $DISKSPCE)"
if [ "$HASSPACE" -eq "$NOSPACE" ]; then echo "WARNING: Insufficient space on backup directory"; exit 1; fi

echo
echo "Xtrabackup started: `date`" | tee -a "${INF_FILE}"
echo

# Keep track if any errors happen
_status=0

#Llet's create the backup
cd $WORK_DIR/bkps/
echo "Backing up with: $_ibx_bkp"
$_ibx_bkp
RETVAR=$?

_end_backup_date=`date`
echo 
echo "Xtrabackup finished: ${_end_backup_date}" | tee -a "${INF_FILE}"
echo

# Check the exit status from innobackupex, but dont exit right away if it failed
if [ "$RETVAR" -gt 0 ]; then 
   _d_inf "ERROR: non-zero exit status of xtrabackup during backup. Something may have failed!"; 
fi

# Sync the binary logs to local stor first.
echo
echo "Syncing binary log snapshots"
#rsync -avzp $BNLGDIR/$BNLGFMT.* $_this_stor/bnlg/
if [ -n "$_last_bkp" ]; then
   _first_bkp_since=$(_sql_first_backup_elapsed)
   > $WORK_DIR/bkps/binlog.index

   echo "Getting a list of binary logs to copy"
   for f in $(cat $BNLGDIR/$BNLGFMT.index); do 
      echo $(basename $f) >> $WORK_DIR/bkps/binlog.index
   done
   if [ "$STOR_CMP" == 1 ]; then
      if [ -f "$STOR_DIR/bkps/${_last_bkp}-xtrabackup_binlog_info.log" ]; then
         _xbinlog_info=$STOR_DIR/bkps/${_last_bkp}-xtrabackup_binlog_info.log
      elif [ -f "$STOR_DIR/bkps/${_last_bkp}/xtrabackup_binlog_info" ]; then
         _xbinlog_info=$STOR_DIR/bkps/${_last_bkp}/xtrabackup_binlog_info
      else
         _xbinlog_info=
      fi
   elif [ -f "$STOR_DIR/bkps/${_last_bkp}/xtrabackup_binlog_info" ]; then
      _xbinlog_info=$STOR_DIR/bkps/${_last_bkp}/xtrabackup_binlog_info
   else
      _xbinlog_info=
   fi

   if [ -n "$_xbinlog_info" -a -f "$_xbinlog_info" ]; then
      echo "Found last binlog information $_xbinlog_info"

      _last_binlog=$(cat $_xbinlog_info|awk '{print $1}')

      cd $BNLGDIR

      if [ "$STOR_CMP" == 1 ]; then
         if [ -f "${_this_stor}/bnlg/${_last_binlog}.tar.gz" ]; then 
            rm -rf "${_this_stor}/bnlg/${_last_binlog}.tar.gz"; 
         fi
         tar czvf "${_this_stor}/bnlg/${_last_binlog}.tar.gz" $_last_binlog
      else
         if [ -f "${_this_stor}/bnlg/${_last_binlog}" ]; then 
            rm -rf "${_this_stor}/bnlg/${_last_binlog}"; 
         fi
         cp -v $_last_binlog "${_this_stor}/bnlg/"
      fi

      for f in $(sed -e "1,/${_last_binlog}/d" $WORK_DIR/bkps/binlog.index); do
         if [ "$STOR_CMP" == 1 ]; then
            tar czvf "${_this_stor}/bnlg/${f}.tar.gz" $f
         else
            cp -v $f "${_this_stor}/bnlg/"
         fi
      done

      if [ -f "${_this_stor}/bnlg/${BNLGFMT}.index" ]; then rm -rf "${_this_stor}/bnlg/${BNLGFMT}.index"; fi
      cp ${BNLGFMT}.index ${_this_stor}/bnlg/${BNLGFMT}.index
      cd $WORK_DIR/bkps/
   fi

   if [ -n "${_first_bkp_since}" -a "${_first_bkp_since}" -gt 0 ]; then
      echo "Deleting archived binary logs older than ${_first_bkp_since} minutes ago"
      find ${_this_stor}/bnlg/ -mmin +$_first_bkp_since -exec rm -rf {} \;
   fi
fi
echo " ... done"

# Create copies of the backup if STOR_DIR and RMTE_DIR+RMTE_SSH is
# specified.
if [ -n "$STOR_DIR" ]; then
   echo
   echo "Copying to immediate storage ${STOR_DIR}/bkps/"
   if [ "$STOR_CMP" == 1 ]; then
      tar czvf ${STOR_DIR}/bkps/${CURDATE}.tar.gz $CURDATE
      cp $_this_bkp/xtrabackup_binlog_info $STOR_DIR/bkps/${CURDATE}-xtrabackup_binlog_info.log
      cp -r $_this_bkp*.log $STOR_DIR/bkps/
   else
      cp -r $_this_bkp* $STOR_DIR/bkps/
   fi

   if [ "$?" -gt 0 ]; then 
      _s_inf "WARNING: Failed to copy ${_this_bkp} to ${STOR_DIR}/bkps/"; 
   # Delete backup on work dir if no apply log is needed
   elif [ "$APPLY_LOG" == 0 ]; then
      rm -rf $WORK_DIR/bkps/*
   # We also delete the previous incremental if the backup has been successful
   elif [ "${BKP_TYPE}" == "incr" ]; then 
      echo "Deleting previous incremental ${WORK_DIR}/bkps/${_inc_basedir}"
      rm -rf ${WORK_DIR}/bkps/${_inc_basedir}*;
   elif [ "${BKP_TYPE}" == "full" ]; then 
      echo "Deleting previous work backups `find -maxdepth 1 -mindepth 1 | sort -n | grep -v $CURDATE|xargs`"
      find -maxdepth 1 -mindepth 1 | sort -n | grep -v $CURDATE|xargs rm -rf 
   fi
   echo " ... done"
fi

if [[ -n "$RMTE_DIR" && -n "$RMTE_SSH" ]]; then
   echo
   echo "Syncing backup sets to remote $RMTE_SSH:$RMTE_DIR/"
   rsync -avzp --delete -e ssh $STOR_DIR/ $RMTE_SSH:$RMTE_DIR/
   if [ "$?" -gt 0 ]; then _s_inf "WARNING: Failed to sync ${STOR_DIR} to $RMTE_SSH:$RMTE_DIR/"; fi
   echo " ... done"
fi

if [ "${BKP_TYPE}" == "incr" ]; then
   set -- $(_sql_incr_bsedir $_week_no)
   _incr_base=$1
   _incr_baseid=$2
   _incr_basedir=${_incr_base}
else
   _incr_baseid=0
   _incr_basedir='0000-00-00_00_00_00'
fi

# Start, whether apply log is enabled
if [ "$APPLY_LOG" == 1 ]; then

if [ -n "${USE_MEMORY}" ]; then _ibx_prep="$_ibx --use-memory=$USE_MEMORY"; fi

if [ "$status" != 1 ]; then
   _start_prepare_date=`date`
   echo "Apply log started: ${_start_prepare_date}" | tee -a "${INF_FILE}"

   if [ "${BKP_TYPE}" == "incr" ];
   then 
      if [ ! -n "$_incr_base" ];
      then
         _d_inf "ERROR: No valid base backup found!";
      fi

      _incr_base=P_${_incr_base}

      if [ ! -d "${WORK_DIR}/bkps/${_incr_base}" ];
      then
         _d_inf "ERROR: Base backup ${WORK_DIR}/bkps/${_incr_base} does not exist.";
      fi
      _ibx_prep="${_ibx_prep} --apply-log ${WORK_DIR}/bkps/${_incr_base} --incremental-dir  ${_this_bkp}"
      echo "Preparing incremental backup with ${_ibx_prep}"
   else
      _apply_to="${WORK_DIR}/bkps/P_${CURDATE}"
      # Check to make sure we have enough disk space to make a copy
      _bu_size=$(_du_r $_this_bkp)
      _du_left=$(_df $WORK_DIR)
      if [ "${_bu_size}" -gt "${_du_left}" ]; then
         _d_inf "ERROR: Apply to copy was specified, however there is not enough disk space left on device.";
      else
         cp -r ${_this_bkp} ${_apply_to}
      fi

      _ibx_prep="${_ibx_prep} --apply-log --redo-only ${_apply_to}"
      echo "Preparing base backup with ${_ibx_prep}"
   fi

   $_ibx_prep
   RETVAR=$?
fi

_end_prepare_date=`date`
echo
echo "Apply log finished: ${_end_prepare_date}" | tee -a "${INF_FILE}"
echo

# Check the exit status from innobackupex, but dont exit right 
# away if it failed
if [ "$RETVAR" -gt 0 ]; then
   _d_inf "ERROR: non-zero exit status of xtrabackup during --apply-log. Something may have failed! Please prepare, I have not deleted the new backup directory.";
fi

# End, whether apply log is enabled
fi

_started_at="STR_TO_DATE('${CURDATE}','%Y-%m-%d_%H_%i_%s')"
if [ "$APPLY_LOG" == 1 ]; then
   _ends_at=`date -d "${_end_prepare_date}" "+%Y-%m-%d %H:%M:%S"`
else
   _ends_at=`date -d "${_end_backup_date}" "+%Y-%m-%d %H:%M:%S"`
fi
_incr_basedir="STR_TO_DATE('${_incr_basedir}','%Y-%m-%d_%H_%i_%s')"
_bu_size=$(_du_h ${_this_bkp})
_du_left=$(_df_h $WORK_DIR)

_sql_save_bkp "${_started_at}" "${_ends_at}" "${_bu_size}" "${STOR_DIR}/bkps/${CURDATE}" "${_incr_basedir}" "${_week_no}" "${_incr_baseid}"

echo "Cleaning up previous backup files:"
# Depending on how many sets to keep, we query the backups table.
# Find the ids of base backups first.
_prune_base=$(_sql_prune_base)
if [ -n "$_prune_base" ]; then
   _prune_list=$(_sql_prune_list $_prune_base)
   if [ -n "$_prune_list" ]; then
      echo "Deleting backups: ${_prune_list}"
      _sql_prune_rows $_prune_base
      cd $STOR_DIR/bkps && rm -rf $_prune_list
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
