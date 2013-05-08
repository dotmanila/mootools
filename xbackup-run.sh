#!/bin/bash

### Local options
WORK_DIR=/ssd/sb/xbackups
BASE_DIR=/ssd/sb/scripts/  
CURDATE=$(date +%Y-%m-%d_%H_%M_%S)
LOG_FILE="${WORK_DIR}/${CURDATE}.log"
MAIL_FROM="root@`hostname`"
MAIL_TO="me@example.com"
MAIL_TO_ERROR="me@example.com"

if [ -f $LOG_FILE ]; then rm -rf $LOG_FILE; fi

$BASE_DIR/xbackup.sh $1 ${CURDATE} 2>&1 | tee $LOG_FILE

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  (echo "Subject: ERROR: MySQL Backup failed on `hostname`";
    cat ${WORK_DIR}/${CURDATE}-info.log;
    if [ -f $LOG_FILE ]; then cat $LOG_FILE; fi;
    ) | /usr/sbin/sendmail -O NoRecipientAction=add-to -f${MAIL_FROM} ${MAIL_TO_ERROR}
else
  (echo "Subject: MySQL Backup complete on `hostname`";
    cat ${WORK_DIR}/${CURDATE}-info.log;
  )  | /usr/sbin/sendmail -O NoRecipientAction=add-to -f${MAIL_FROM} ${MAIL_TO}
fi


