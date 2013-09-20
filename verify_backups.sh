#!/bin/bash
# Script to validate backups
# Michael Coburn, Percona - 2013-08-06

YESTERDAY=`date --date="yesterday" +%Y%m%d`
ROOTDIR="/data/percona"
LOG="${ROOTDIR}/activity_`date +%F`.log"
STATUSLOG="${ROOTDIR}/status_`date +%F`.log"
INSTANCESOURCE="${ROOTDIR}/instances"
INSTANCES=`awk '{print $1}' $INSTANCESOURCE`
BACKUPDIR="/data/backup-snapshots"
PORT=9999
SERVERID=9999
USER="mysql"
INITFILE="init-replication"

# insert header, zero out the file
echo -e "INST\tSUCCESS" > $STATUSLOG

for instance in $INSTANCES; do
        pid='undef'
        DATADIR="${ROOTDIR}/${instance}"
        echo "++++"
        echo "`date` -- $instance -- INSTANCE: $instance" | tee --append $LOG
        echo "++++"
        WORKDIR="${ROOTDIR}/$instance"
        echo "++++"
        echo "`date` -- $instance -- CREATING DIRECTORY $WORKDIR" | tee --append $LOG
        echo "++++"
        rm -rfv $WORKDIR
        mkdir $WORKDIR
        cd $WORKDIR
        echo "++++"
        echo "`date` -- $instance -- UNPACKING xbstream FILE" | tee --append $LOG
        echo "++++"
        cat $BACKUPDIR/${instance}_${YESTERDAY}*.xbs \
        | xbstream -x -v -C .
        echo "++++"
        echo "`date` -- $instance -- UNCOMPRESSING FILES WITH qpress" | tee --append $LOG
        echo "++++"
        for bf in `find . -iname "*\.qp"`;
                do qpress -dvfT12 $bf $(dirname $bf) && rm -vf $bf;
        done
        echo "++++"
        echo "`date` -- $instance -- APPLYING LOGS" | tee --append $LOG
        echo "++++"
        innobackupex --use-memory=5G --apply-log $WORKDIR
        echo "++++"
        echo "`date` -- $instance -- UPDATING PERMISSIONS, CLEANING UP FILES" | tee --append $LOG
        echo "++++"
        chown -R mysql:mysql $WORKDIR
        rm -vf ib_logfile*
        echo "++++"
        echo "`date` -- $instance -- SETTING UP REPLICATION" | tee --append $LOG
        echo "++++"
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
                echo "++++"
                echo "`date` -- $instance -- DUMPING INITFILE" | tee --append $LOG
                echo "`date` -- $instance -- REPLICATION INFO:" | tee --append $LOG
                echo "`date` -- $instance -- $CHANGE_MASTER" | tee --append $LOG
                echo "++++"
                cat $INITFILE
                REPOPTS="--init-file=${INITFILE}"
        else
                echo "++++"
                echo "`date` -- $instance -- NO REPLICATION INFORMATION, SKIPPING INITFILE" | tee --append $LOG
                echo "++++"
        fi
        INNODBPATH="`grep $instance $INSTANCESOURCE | awk '{print $3}'`"
        echo "++++"
        echo "`date` -- $instance -- InnoDB path is: $INNODBPATH" | tee --append $LOG
        echo "++++"
        echo "++++"
        echo "`date` -- $instance -- STARTING mysqld" | tee --append $LOG
        echo "++++"
        mysqld --no-defaults $REPOPTS --innodb_data_file_path=${INNODBPATH} --port=${PORT} --server_id=${SERVERID} --user=${USER} --datadir=${DATADIR} --log-error=${DATADIR}/${PORT}.err &
        RETVAL=$?
        # Did it start?
        if [ "$RETVAL" -ne 0 ] ;
        then
                echo "++++"
                echo "`date` -- $instance -- mysqld DID NOT START!! EXITING" | tee --append $LOG
                echo "++++"
                exit 1;
        else
                echo "++++"
                echo "`date` -- $instance -- mysqld started." | tee --append $LOG
                echo "++++"
        fi
        sleep 15
        # get PID
        pid=`ps -ef | grep "server_id=9999"  | grep -v grep | awk '{print $2}'`
        # Get slave thread status
        tstatus=`mysql --host=127.0.0.1 --port=9999 -e "SHOW SLAVE STATUS\G" | egrep -c "Yes"`
        if [ "$tstatus" = 2 ] ;
        then
                echo "++++"
                echo "`date` -- $instance -- Slave running successfully for instance: $instance" | tee --append $LOG
                echo "++++"
                echo -e "$instance\tYES" >> $STATUSLOG
        else
                if [ -e "${REPOPTS}" ] ;
                then
                        echo "++++"
                        echo "`date` -- $instance -- Slave not running successfully for instance: $instance" | tee --append $LOG
                        echo "`date` -- $instance -- Logging SLAVE STATUS and ERROR data" | tee --append $LOG
                        echo "++++"
                        echo -e "$instance\tNO" >> $STATUSLOG
                        #write out slave status for debugging
                        master_version=`mysql --host=${MASTER_HOST} --port=${instance} --user="replica" --password='need_more_data' -e "SELECT @@version"`
                        slave_status=`mysql --host=127.0.0.1 --port=9999 -e "SHOW SLAVE STATUS\G"`
                        log_err=`cat ${DATADIR}/${PORT}.err`
                        echo $master_version >> $LOG
                        echo $slave_status >> $LOG
                        echo $log_err >> $LOG
                else
                        # There was no binary log coordinate so we couldn't start replication
                        # MySQL is running but we haven't validate dataset
                        echo "++++"
                        echo "`date` -- $instance -- Replication was never started. MySQL is up but we haven't validated the dataset." | tee --append $LOG
                        echo "++++"
                        echo -e "$instance\tUNK" >> $STATUSLOG
                        #write out slave status for debugging
                        master_version=`mysql --host=${MASTER_HOST} --port=${instance} --user="replica" --password='need_more_data' -e "SELECT @@version"`
                        slave_status=`mysql --host=127.0.0.1 --port=9999 -e "SHOW SLAVE STATUS\G"`
                        log_err=`cat ${DATADIR}/${PORT}.err`
                        echo $master_version >> $LOG
                        echo $slave_status >> $LOG
                        echo $log_err >> $LOG
                fi
        fi
        # stop mysqld
        echo "++++"
        echo "`date` -- $instance -- Killing mysqld on port $PORT, Deleting files from $WORKDIR" | tee --append $LOG
        echo "++++"
        kill -9 $pid
        # clean up directory
        cd $ROOTDIR
        rm -rf $WORKDIR
        echo "++++"
        echo "`date` -- $instance -- DONE with instance: $instance" | tee --append $LOG
        echo "++++"
done
