#!/bin/bash

VOLUME_HOME="/data/mysql/lib"
CONF_FILE="/etc/mysql/my.cnf"
LOG="/var/log/mysql/error.log"

# Set permission of config file
chmod 644 ${CONF_FILE}
chmod 644 /etc/mysql/conf.d/mysqld_charset.cnf
rm -f /etc/mysql/conf.d/mysqld_safe_syslog.cnf
rm -f /var/run/mysqld/*

chown -R mysql:mysql /var/lib/mysql
chown -R mysql:mysql /var/log/mysql
chown -R mysql:mysql /var/run/mysqld

StartMySQL()
{
    /usr/bin/mysqld_safe > /dev/null 2>&1 &

    # Time out in 1 minute
    LOOP_LIMIT=13
    for (( i=0 ; ; i++ )); do
        if [ ${i} -eq ${LOOP_LIMIT} ]; then
            echo "Time out. Error log is shown as below:"
            tail -n 100 ${LOG}
            exit 1
        fi
        echo "=> Waiting for confirmation of MySQL service startup, trying ${i}/${LOOP_LIMIT} ..."
        sleep 5
        mysql -uroot -e "status" > /dev/null 2>&1 && break
    done
}

CreateMySQLUser()
{
	StartMySQL
	if [ "$MYSQL_PASS" = "**Random**" ]; then
	    unset MYSQL_PASS
	fi

	PASS=${MYSQL_PASS:-$(pwgen -s 12 1)}
	_word=$( [ ${MYSQL_PASS} ] && echo "preset" || echo "random" )
	echo "=> Creating MySQL user ${MYSQL_USER} with ${_word} password"

       `mysql -uroot -e "CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${PASS}'"`
       `mysql -uroot -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION"`
	# for developpment's environement
       `mysql -uroot -e "CREATE USER 'root'@'%'"`
       `mysql -uroot -e "GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'%' WITH GRANT OPTION"`


	echo "=> Done!"

	echo "========================================================================"
	echo "You can now connect to this MySQL Server using:"
	echo ""
	echo "    mysql -u$MYSQL_USER -p$PASS -h<host> -P<port>"
	echo ""
	echo "Please remember to change the above password as soon as possible!"
	echo "========================================================================"

	mysqladmin -uroot shutdown
}

ImportSql()
{
	StartMySQL

	for FILE in ${STARTUP_SQL}; do
	   echo "=> Importing SQL file ${FILE}"
	   mysql -uroot < "${FILE}"
	done

	mysqladmin -uroot shutdown
}

#######################################################################
# private fonction for couchbase initialisation
#######################################################################
check() {
  if [ -z "$COUCHBASE_USER" ] || [ -z "$COUCHBASE_PASS" ]; then
 	PASS=${COUCHBASE_PASS:-$(pwgen -s 12 1)}
	_word=$( [ ${COUCHBASE_PASS} ] && echo "preset" || echo "random" )
 	COUCHBASE_USER="admin";
 	COUCHBASE_PASS=${PASS};
	echo "=> Creating CouchBase user ${COUCHBASE_USER} with ${PASS} as password"
  fi
}

start_couchbase() {
  echo "starting couchbase"
  /etc/init.d/couchbase-server start

#  trap "/etc/init.d/couchbase-server stop" exit INT TERM
}

get_ip() {
  local eth0=$(ip addr show dev eth0 | sed -e's/^.*inet \([^ ]*\)\/.*$/\1/;t;d')
  if [[ -z "$eth0" ]]; then
    local eth1=$(ip addr show dev eth1 | sed -e's/^.*inet \([^ ]*\)\/.*$/\1/;t;d')
    if [[ -z "$eth1" ]]; then
      local enp0s8=$(ip addr show dev enp0s8 | sed -e's/^.*inet \([^ ]*\)\/.*$/\1/;t;d')
      echo $enp0s8
    else
      echo $eth1
    fi
  else
    echo $eth0
  fi
}

start() {
  local counter=1
  "$@"
  while [ $? -ne 0 ]; do
    if [[ "$counter" -ge 10 ]]; then
      echo "server didn't start in 50 seconds, exiting now..."
      exit
    fi
    counter=$[$counter +1]
    echo "waiting for couchbase to start..."
    sleep 5
    "$@"
  done
}

cli() {
  start $@
}

cluster_init() {
  check
  local ip="localhost" #$(get_ip)
  if [ -z "$CLUSTER_RAM_SIZE" ]; then
    CLUSTER_RAM_SIZE=300
  fi
  echo "initializing cluster..."
  start /opt/couchbase/bin/couchbase-cli cluster-init -c $ip:8091 -u "$COUCHBASE_USER" -p "$COUCHBASE_PASS" --cluster-init-ramsize=$CLUSTER_RAM_SIZE --cluster-username="$COUCHBASE_USER" --cluster-password="$COUCHBASE_PASS"
}

bucket_init() {
  check
  local ip="localhost" #$(get_ip)
  echo "initializing bucket..."
  start /opt/couchbase/bin/couchbase-cli bucket-create --bucket=pco_sso --bucket-type=membase --enable-flush=1 --bucket-port=18887 --bucket-ramsize=100 --bucket-replica=1 -c $ip:8091 -u "$COUCHBASE_USER" -p "$COUCHBASE_PASS"
  start /opt/couchbase/bin/couchbase-cli bucket-create --bucket=pco_infocentre --bucket-type=membase --enable-flush=1 --bucket-port=18888 --bucket-ramsize=100 --bucket-replica=1 -c $ip:8091 -u "$COUCHBASE_USER" -p "$COUCHBASE_PASS"
  start /opt/couchbase/bin/couchbase-cli bucket-create --bucket=pco_cache --bucket-type=membase --enable-flush=1 --bucket-port=18886 --bucket-ramsize=100 --bucket-replica=1 -c $ip:8091 -u "$COUCHBASE_USER" -p "$COUCHBASE_PASS"
}
check_init() {
  check
  local ip="localhost" #$(get_ip)
  rc=`/opt/couchbase/bin/couchbase-cli bucket-list -c $ip:8091 -u "$COUCHBASE_USER" -p "$COUCHBASE_PASS"`;
  if [[ $rc == *"pco_cache"* ]]; then
     echo 0
  else
     echo 1
  fi
}

##################################################
####
####       STARTING APPLICATIONS
####
##################################################
if [ ! -f  /installed.lock  ]; then

	#####################
	# sshd Start
	#####################
	pass=`mkpasswd bench`
	`useradd --password $pass --gid ssh --groups ssh,users,adm sshuser`
	/usr/bin/service ssh start
	echo "ssh started ..."

	#####################
	# Redis Start
	#####################
	/usr/bin/redis-server /etc/redis/redis.conf
	echo "redis-server started ..."

	#####################
	# CouchBase Start
	#####################
	cd /opt/couchbase
	start_couchbase;
	cluster_init;
	if [ $(check_init) -ne 0 ]; then bucket_init; fi

	######################
	# Mysql Start
	######################
	if [ ! -z ${VOLUME_HOME}  ]; then rm -rf  ${VOLUME_HOME}/mysql ; cp -r /var/lib/mysql/mysql ${VOLUME_HOME}; chown -R mysql:mysql ${VOLUME_HOME}; fi
	echo "=> An empty or uninitialized MySQL volume is detected in $VOLUME_HOME"
	echo "=> Installing MySQL ..."
	if [ ! -f /usr/share/mysql/my-default.cnf ] ; then
	    cp /etc/mysql/my.cnf /usr/share/mysql/my-default.cnf
	fi
	mysql_install_db > /dev/null 2>&1
	echo "=> Done!"
	echo "=> Creating admin user ..."
	CreateMySQLUser

	if [ -n "${STARTUP_SQL}" ]; then
	    echo "=> Initializing DB with ${STARTUP_SQL}"
	    ImportSql
	fi
	echo "NE PAS SUPPRIMER SVP" > /installed.lock

	exec /usr/bin/mysqld_safe
else
        /usr/bin/service sshd start
        echo "sshd started ..."
        /usr/bin/redis-server /etc/redis/redis.conf
        echo "redis-server started ..."
	start_couchbase
	if [ -n "${STARTUP_SQL}" ]; then
	    echo "=> Initializing DB with ${STARTUP_SQL}"
	    ImportSql
	fi
	exec /usr/bin/mysqld_safe
fi
cd /
