#!/bin/env bash

WORK_DIR=$1
MYSQL_UTILITIES_URL=http://mysql.mirrors.hoobly.com/Downloads/MySQLGUITools/mysql-utilities-1.4.2.tar.gz
MYSQL_CONNECTOR_URL=http://mysql.mirrors.hoobly.com/Downloads/Connector-Python/mysql-connector-python-1.2.1.tar.gz

_echo() {
   echo "$(date +%Y-%m-%d_%H_%M_%S) fabric-init $1"
}

_die() {
   _echo $1
   kill -INT $$
}

_run() {
   local _cmd=$1
   local _ret=$2

   $_cmd
   _val=$?

   if [ "x$_val" != "x$_ret" ]; then
      _die "FATAL: '$_cmd' failed!"
   fi
}

_workdir_valid() {
   if [ "x$1" == "x" ]; then
      _die 'FATAL: Specified WORK_DIR is empty!'
   fi
}

_workon() {
   local WORK_DIR=${1:-$FABRIC_WORK_DIR}
   _workdir_valid $WORK_DIR
   cd $WORK_DIR
   > .vars
   echo "export PYTHONPATH=$PYTHONPATH" >> .vars
   echo "export PATH=$PATH" >> .vars
   echo "PS1='$PS1'" >> .vars
   echo "FABRIC_WORK_DIR=" >> .vars

   export PATH=$WORK_DIR/utils/usr/bin:$PATH
   export PYTHONPATH=.:$(find $WORK_DIR -type d -name *site-packages)
   export PS1='fabric> '
   export FABRIC_WORK_DIR=$WORK_DIR 
}

_eod() {
   source ./.vars
}

_init_mysql() {
   local WORK_DIR=${1:-$FABRIC_WORK_DIR}
   _workdir_valid $WORK_DIR
   cd $WORK_DIR

   local VERSION=$2
   local FGROUPS=${3:-2}
   local BASE_PORT=${4:-17600}

   for sb in $(seq 1 $FGROUPS); do
      make_replication_sandbox --replication_directory=fabric_group_$sb \
         --sandbox_base_port=$BASE_PORT --how_many_slaves=1 \
         --upper_directory=$WORK_DIR --node_options='--my_clause=gtid_mode=ON --my_clause=log-bin=mysql-bin --my_clause=log-slave-updates --my_clause=enforce-gtid-consistency' \
         $VERSION

      $WORK_DIR/fabric_group_$sb/m -uroot -pmsandbox \
         -BNe "GRANT ALL ON *.* TO 'fabric'@'127.0.0.1' IDENTIFIED BY 'fabric'"
      BASE_PORT=$(($BASE_PORT+2))
   done

   make_sandbox $VERSION -- --no_show --sandbox_directory=fabric_store \
      --sandbox_port=$BASE_PORT --upper_directory=$WORK_DIR
   $WORK_DIR/fabric_store/use -uroot -pmsandbox \
      -BNe "GRANT ALL ON fabric.* TO 'fabric'@'127.0.0.1' IDENTIFIED BY 'fabric'"
}

_init_fabric() {
   local WORK_DIR=${1:-$FABRIC_WORK_DIR}
   _workdir_valid $WORK_DIR
   cd $WORK_DIR

   _teardown_fabric $WORK_DIR
   FABRIC_PORT=$(cat $WORK_DIR/fabric_store/my.sandbox.cnf|grep -E '^port'|awk '{print $3}'|head -n1)
  
   $WORK_DIR/fabric_store/use -uroot -pmsandbox \
      -BNe "CREATE DATABASE IF NOT EXISTS fabric"
 
   mkdir -p $WORK_DIR/utils/usr/etc/mysql && \
      cat $WORK_DIR/fabric.cfg-template > $WORK_DIR/utils/usr/etc/mysql/fabric.cfg && \
      sed -i 's,WORK_DIR,'"$WORK_DIR"',' $WORK_DIR/utils/usr/etc/mysql/fabric.cfg && \
      sed -i 's,FABRIC_SYSCONFDIR,'"$WORK_DIR/utils/usr/etc/mysql"',' $WORK_DIR/utils/usr/etc/mysql/fabric.cfg && \
      sed -i 's,FABRIC_STORE_PORT,'"$FABRIC_PORT"',' $WORK_DIR/utils/usr/etc/mysql/fabric.cfg && \
      _echo "INFO: Setting up Fabric Storage System" && \
      mysqlfabric manage setup && \
      _echo "INFO: Starting Fabric server" && \
      mysqlfabric manage start --daemonize && \
      mysqlfabric manage ping

   local fabric_is_running=$?
   if [ "x$fabric_is_running" == "x0" ]; then
      for d in $(ls $WORK_DIR|grep fabric_group_); do
         mysqlfabric group create $d
         mysqlfabric group add $d 127.0.0.1:$(cat $WORK_DIR/$d/master/my.sandbox.cnf|grep -E '^port'|awk '{print $3}'|head -n1)
         mysqlfabric group add $d 127.0.0.1:$(cat $WORK_DIR/$d/node1/my.sandbox.cnf|grep -E '^port'|awk '{print $3}'|head -n1)
      done

      mysqlfabric group lookup_groups
   fi
}

_teardown_mysql() {
   local WORK_DIR=${1:-$FABRIC_WORK_DIR}
   _workdir_valid $WORK_DIR
   cd $WORK_DIR

   _teardown_fabric $WORK_DIR

   _echo "INFO: Tearing down Fabric nodes"
   for sb in $(ls $WORK_DIR|grep fabric_group_); do
      sbtool -o delete --source_dir=$WORK_DIR/$(basename $sb)
   done

   _echo "INFO: Tearing down Fabric store node"
   sbtool -o delete --source_dir=$WORK_DIR/fabric_store
}

_teardown_fabric() {
   local WORK_DIR=${1:-$FABRIC_WORK_DIR}
   _workdir_valid $WORK_DIR
   cd $WORK_DIR

   _echo "INFO: Tearing down Fabric storage" 
 
   if [ -f $WORK_DIR/utils/usr/etc/mysql/fabric.cfg ]; then
      mysqlfabric manage stop && \
      mysqlfabric manage teardown && \
         rm -rf $WORK_DIR/utils/usr/etc/mysql/fabric.cfg
   fi
}

_init_utils() {
   local WORK_DIR=${1:-$FABRIC_WORK_DIR}
   _workdir_valid $WORK_DIR
   cd $WORK_DIR
   _echo "INFO: Preparing mysql-utilities"
   local TARBALL=$(basename $MYSQL_UTILITIES_URL)
   local UTILDIR=$(echo $TARBALL|sed -e 's/.tar.gz//g')

   if [ ! -f $TARBALL ]; then
      _run "wget $MYSQL_UTILITIES_URL" 0
   fi

   tar xzvf $TARBALL && \
      mv -f $UTILDIR utils && \
      cd utils && \
      python setup.py build && \
      python setup.py install --root=$WORK_DIR/utils && \
      cd ../

   _echo "INFO: Preparing MySQL Connector-Python"
   local TARBALL=$(basename $MYSQL_CONNECTOR_URL)
   local CONRDIR=$(echo $TARBALL|sed -e 's/.tar.gz//g')

   if [ ! -f $TARBALL ]; then
      _run "wget $MYSQL_CONNECTOR_URL" 0
   fi
   
   tar xzvf $TARBALL && \
      cd $CONRDIR && \
      python setup.py build && \
      python setup.py install --root=$WORK_DIR/utils && \
      cd ../

   [ "x" != "x$FABRIC_WORK_DIR" ] && _eod && _workon $WORK_DIR
}

_teardown() {
   local WORK_DIR=${1:-$FABRIC_WORK_DIR}
   _workdir_valid $WORK_DIR
   cd $WORK_DIR

   _echo "INFO: Tearing down Fabric environment!"
   _teardown_mysql $WORK_DIR
   rm -rf $WORK_DIR/utils
   rm -rf $WORK_DIR/*.log
   rm -rf $WORK_DIR/mysql-connector-*
   rm -rf $WORK_DIR/mysql-utilities-*
   _eod
}

_init_all() {
   local WORK_DIR=${1:-$FABRIC_WORK_DIR}
   _workdir_valid $WORK_DIR
   cd $WORK_DIR

   _teardown $WORK_DIR
   _workon $WORK_DIR
   _init_utils $WORK_DIR
   _init_mysql $WORK_DIR 5.6.17 2
   _init_fabric $WORK_DIR
   [ "x" == "x$FABRIC_WORK_DIR" ] && _eod && _workon $WORK_DIR
}

echo ""
echo " Fabric System Wrapper"
echo " ---------------------"
echo " "
echo " Initializer ready for these commands:"
echo " "
echo " _init_all <WORK_DIR>"
echo "       Meta function the bootstraps everything from 0 to a full running"
echo "       Fabric system using 5.6.17 and 2 groups. Your system should be able"
echo "       create MySQL sandboxes properly with 'make_sandbox 5.6.17' command"
echo " _teardown [<WORK_DIR>]"
echo "       Teardown the whole Fabric system, WORK_DIR is optional if you are"
echo "       operating inside a Fabric environment via _workon"
echo " _workon <WORK_DIR>"
echo "       Setup the environment for this Fabric cluster within WORK_DIR"
echo " _init_utils [<WORK_DIR>]"
echo "       Setup MySQL Utilities inside WORK_DIR"
echo " _init_mysql <WORK_DIR> <SANDBOX_VERSION> <NUMBER_OF_GROUPS>"
echo "       Setup the MySQL nodes that will consist of Fabric groups and storage."
echo "       This function uses MySQL Sandbox and accepts the MySQL version within"
echo "       you \$SANDBOX_BINARY directory"
echo " _init_fabric [<WORK_DIR>]"
echo "       Setup and start the Fabric system then create and add the HA groups"
echo "       from _init_mysql"
echo " _eod"
echo "       Exits the current Fabric environment which you have entered with '_workon'"
echo " GOOD LUCK!"
echo "" 

