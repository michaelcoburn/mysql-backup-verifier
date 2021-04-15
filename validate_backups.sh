#!/bin/bash
# Script to validate backups
# Michael Coburn, Percona - 2013-08-06
#
# Stands up mysqld on localhost, connects to master,
# allows replication to run for a bit, makes determination
# whether backup is good or not
#
# Script accepts 2 arguments:
# $1 = mode , which is either test or prod
# $2 = instances file

# Variable definitions
YESTERDAY=`date --date="2 days ago" +%Y%m%d`
ROOTDIR="/data/percona"
INSTANCESFILE=$2
INSTANCESOURCE="${ROOTDIR}/${INSTANCESFILE}"
INSTANCES=`awk '{print $1}' $INSTANCESOURCE`
BACKUPDIR="/data/backup-snapshots"
USER="mysql"
INITFILE="init-replication"
# Functions
NORMAL=$(tput sgr0)
GREEN=$(tput setaf 2; tput bold)
YELLOW=$(tput setaf 3)
RED=$(tput setaf 1)

function red() {
    echo -e "$RED****$NORMAL" | tee --append $LOG
    echo -e "$RED`date` -- $instance -- $*$NORMAL"   | tee --append $LOG
    echo -e "$RED****$NORMAL" | tee --append $LOG
}
function green() {
    echo -e "$GREEN++++$NORMAL" | tee --append $LOG
    echo -e "$GREEN`date` -- $instance -- $*$NORMAL"   | tee --append $LOG
    echo -e "$GREEN++++$NORMAL" | tee --append $LOG
}
function yellow() {
    echo -e "$YELLOW----$NORMAL" | tee --append $LOG
    echo -e "$YELLOW`date` -- $instance -- $*$NORMAL"   | tee --append $LOG
    echo -e "$YELLOW----$NORMAL" | tee --append $LOG
}
MODE=$1
if [ "$MODE" = "test" ] ; then
    LOG="${ROOTDIR}/TEST_activity_`date +%F`.log"
    STATUSLOG="${ROOTDIR}/TEST_status_`date +%F`.log"
    PORT=9998
    SERVERID=9998
    IS_TEST="true"
    yellow "IN TEST MODE"
elif [ "$MODE" = "prod" ] ; then
    LOG="${ROOTDIR}/activity_`date +%F`.log"
    STATUSLOG="${ROOTDIR}/status_`date +%F`.log"
    PORT=9999
    SERVERID=9999
    green "IN PRODUCTION MODE"
fi

# insert header, zero out the file
echo -e "INST\tSUCCESS" > $STATUSLOG

# main application loop
for instance in $INSTANCES; do
    pid='undef'
    # Set up the environment
    DATADIR="${ROOTDIR}/${instance}"
    green "BEGINNING WORK ON INSTANCE: $instance"
    WORKDIR="${ROOTDIR}/$instance"
    green "CREATING WORKING DIRECTORY $WORKDIR"
    rm -rfv $WORKDIR
    mkdir $WORKDIR
    cd $WORKDIR
    # Unpack xbstream file
    XBSTREAM="$BACKUPDIR/${instance}_${YESTERDAY}*.xbs"
    green "UNPACKING xbstream FILE: $XBSTREAM"
    cat $XBSTREAM \
    | xbstream -x -v -C .
    green "UNCOMPRESSING FILES WITH qpress"
    for bf in `find . -iname "*\.qp"`;
        do qpress -dvfT12 $bf $(dirname $bf) && rm -vf $bf;
    done
    # do crash recovery
    green "APPLYING LOGS"
    innobackupex --use-memory=5G --apply-log $WORKDIR
    green "UPDATING PERMISSIONS, CLEANING UP FILES"
    chown -R mysql:mysql $WORKDIR
    rm -vf ib_logfile*
    # Configure replication
    green "SETTING UP REPLICATION"
    if [ -e "xtrabackup_binlog_pos_innodb" ] ;
        then
        MASTER_HOST=`grep $instance $INSTANCESOURCE | awk '{print $2}'`
        # Find the field position of the binary log filename
        count_slashes=`grep -o "/" xtrabackup_binlog_pos_innodb | wc -l`
        if [ "$count_slashes" -eq 4 ] ;
        then
            MASTER_LOG_FILE=`awk -F '/' '{print $5}' xtrabackup_binlog_pos_innodb | awk '{print $1}'`
        else
            MASTER_LOG_FILE=`awk -F '/' '{print $6}' xtrabackup_binlog_pos_innodb | awk '{print $1}'`
        fi
        MASTER_LOG_POS=`awk '{print $2}' xtrabackup_binlog_pos_innodb`
        CHANGE_MASTER="CHANGE MASTER TO MASTER_HOST=\"${MASTER_HOST}\", MASTER_PORT=${instance}, MASTER_USER='replica', MASTER_PASSWORD='need_more_data', MASTER_LOG_FILE=\"$MASTER_LOG_FILE\", MASTER_LOG_POS=$MASTER_LOG_POS;"
        echo $CHANGE_MASTER > $INITFILE
        echo "START SLAVE;" >> $INITFILE
        green "DUMPING INITFILE"
        green "REPLICATION INFO:"
        yellow "$CHANGE_MASTER"
        REPOPTS="--init-file=${INITFILE}"
    else
        yellow "NO REPLICATION INFORMATION, SKIPPING INITFILE"
    fi
    INNODBPATH="`grep $instance $INSTANCESOURCE | awk '{print $3}'`"
    green "InnoDB path is: $INNODBPATH"
    green "STARTING mysqld"
    mysqld --no-defaults $REPOPTS --innodb_data_file_path=${INNODBPATH} --port=${PORT} --server_id=${SERVERID} --user=${USER} --datadir=${DATADIR} --log-error=${DATADIR}/${PORT}.err &
    RETVAL=$?
    # Did it start?
    if [ "$RETVAL" -ne 0 ] ;
    then
        # Move on to next instance, we can't do any work here anymore...
        red "mysqld DID NOT START!! EXITING"
        exit 1;
    else
        green "mysqld started."
    fi
    # Let the instance run for a bit
    sleep 15
    # get PID
    pid=`ps -ef | grep "server_id=$SERVERID"  | grep -v grep | awk '{print $2}'`
    # Get slave thread status
    tstatus=`mysql --host=127.0.0.1 --port=$SERVERID -e "SHOW SLAVE STATUS\G" | egrep -c "Yes"`
    if [ "$tstatus" = 2 ] ;
    then
        green "Slave running successfully for instance: $instance"
        echo -e "$instance\tYES" >> $STATUSLOG
    else
        if [ -e "${REPOPTS}" ] ;
        then
            red "Slave not running successfully for instance: $instance"
            red "Logging SLAVE STATUS and ERROR data"
            echo -e "$instance\tNO" >> $STATUSLOG
            #write out slave status for debugging
            master_version=`mysql --host=${MASTER_HOST} --port=${instance} --user="replica" --password='need_more_data' -e "SELECT @@version"`
            slave_status=`mysql --host=127.0.0.1 --port=$SERVERID -e "SHOW SLAVE STATUS\G"`
            log_err=`cat ${DATADIR}/${PORT}.err`
            echo $master_version >> $LOG
            echo $slave_status >> $LOG
            echo $log_err >> $LOG
        else
            # There was no binary log coordinate so we couldn't start replication
            # MySQL is running but we haven't validate dataset
            yellow "Replication was never started. MySQL is up but we haven't validated the dataset."
            echo -e "$instance\tUNK" >> $STATUSLOG
            #write out slave status for debugging
            master_version=`mysql --host=${MASTER_HOST} --port=${instance} --user="replica" --password='need_more_data' -e "SELECT @@version"`
            slave_status=`mysql --host=127.0.0.1 --port=$SERVERID -e "SHOW SLAVE STATUS\G"`
            log_err=`cat ${DATADIR}/${PORT}.err`
            echo $master_status >> $LOG
            echo $slave_status >> $LOG
            echo $log_err >> $LOG
        fi
    fi
    # stop mysqld
    if [ -n "$IS_TEST" ] ; then
        red "NOT KILLING mysqld on port $PORT, or deleting files from $WORKDIR"
        exit 0;
    else
        green "Killing mysqld on port $PORT, Deleting files from $WORKDIR"
        kill -9 $pid
        # clean up directory
        cd $ROOTDIR
        rm -rf $WORKDIR
    fi
    green "DONE with instance: $instance"
done
exit 0;
