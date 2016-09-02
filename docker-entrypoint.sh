#!/bin/bash

SECRETS_PATH=${SECRETS_PATH:-/etc/galera-secrets}
DATADIR=${DATADIR:-/var/lib/mysql}
RECONCILE_MASTER_IF_DOWN=${RECONCILE_MASTER_IF_DOWN:-true}
CONTACT_PEERS_FOR_WSREP=true
WAIT_FOR_SECRETS=true
WAIT_FOR_SECRETS_FILES="wsrep-sst-password mysql-root-password"

#SECRETS_ENV_FILE - set to specify an environment file with secrets...

set -e
#
# This script does the following:
#
# 1. Sets up database privileges by building an SQL script
# 2. MySQL is initially started with a permissions script a first time
# 3. Modify my.cnf and cluster.cnf to reflect available nodes to join
# 4. Recovers from complete cluster shutdown by polling for latest seq number from peers
#

function log() {

  local msg=${1}

  echo "INIT:${1}"

}

function is_service_for_another_node() {
  local service_name=${1}
  if [ $(expr "$HOSTNAME" : "${service_name}") -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

function need_to_poll() {

  # poll if:
  # 1. No nodes running AND a service HAS been defined for another host

  # Don't poll if:
  # 1. ANY nodes running.
  # 2. If this is the only node with a service.

  if [ ${RUNNING_SERVICES} -gt 0 ]; then
    log "Other nodes running..."
    return 1 # Don't Poll
  else
    log "No nodes running..."
    if [ ${DETECTED_SERVICES} -le 1  ]; then
      if [ $(expr "$HOSTNAME" : "pxc-node${SERVICE_UP_ID}") -eq 0 ]; then
        # The only service defined is for this host (which is NOT up)...
        # No need to poll
        log "Only one service defined and it is for this host - NO poll."
        return 1
      fi
    fi
    # POLL - other services defined but not running!
    return 0
  fi
}

function poll_for_master() {

  local service_hosts=${1}

  log "Existing cluster down, starting polling to ${service_hosts}..."
  /opt/recover_service/wait_for_master.rb ${service_hosts} || ret=$?
  return ${ret}
}


function add_to_wsrep() {
  local test_addr=${1}
  if is_service_for_another_node ${test_addr} ; then
    if [ "${CONTACT_PEERS_FOR_WSREP}" == "true" ] ; then
      if cat < /dev/null > /dev/tcp/${test_addr}/4567 ; then
        log "${NODE_SERVICE_HOST}:CONTACT MADE"
        return 0
      else
        log "${NODE_SERVICE_HOST}:NO CONTACT"
        return 1
      fi
    else
      log "${NODE_SERVICE_HOST}:CONTACT NOT REQUIRED"
      return 0
    fi
  else
    log "${NODE_SERVICE_HOST}:NEVER ADD THIS HOST TO WSREP"
    return 1
  fi
}

function detect_services_and_set_wsrep() {
  DETECTED_SERVICES=0
  RUNNING_SERVICES=0

  # if empty, set to 'gcomm://'
  # NOTE: this list does not imply membership.
  # It only means "obtain SST and join from one of these..."
  if [ -z "$WSREP_CLUSTER_ADDRESS" ]; then
    WSREP_CLUSTER_ADDRESS="gcomm://"
  fi

  for NUM in `seq 1 ${NUM_NODES}`; do
    NODE_DNS="pxc-node${NUM}"
    NODE_SERVICE_HOST="PXC_NODE${NUM}_SERVICE_HOST"

    if [ -n "${USE_IP}" ]; then
      # Get IP from kubernetes env var
      NODE_ADDR=${!NODE_SERVICE_HOST}
    else
      # Use service DNS name...
      NODE_ADDR=${NODE_DNS}
    fi

    # Ensure the reconciliation service uses ALL nodes...
    if [ -z ${SERVICE_HOSTS} ]; then
      SERVICE_HOSTS="${NODE_ADDR}"
    else
      SERVICE_HOSTS="${SERVICE_HOSTS},${NODE_ADDR}"
    fi

    if is_service_for_another_node "${NODE_DNS}" ; then
      if [ -z ${RECOVERY_HOSTS} ]; then
        RECOVERY_HOSTS="${NODE_DNS}"
      else
        RECOVERY_HOSTS="${RECOVERY_HOSTS},${NODE_DNS}"
      fi
    fi

    # if set, the server has been previously loaded...
    if [ -n "${!NODE_SERVICE_HOST}" ]; then
      DETECTED_SERVICES=$(( ${DETECTED_SERVICES} + 1 ))
      log "${NODE_SERVICE_HOST}:SERVICE EXISTS"
      SERVICE_UP_ID=${NUM}
      if add_to_wsrep ${NODE_ADDR} ; then
        RUNNING_SERVICES=$(( ${RUNNING_SERVICES} + 1 ))
        log "${NODE_SERVICE_HOST}:IN SERVICE"
        # if not its own IP, then add it
        if is_service_for_another_node "${NODE_DNS}" ; then
          # if not the first bootstrap node add comma
          if [ $WSREP_CLUSTER_ADDRESS != "gcomm://" ]; then
            WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS},"
          fi
          # append
          WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS}${NODE_ADDR}"
        fi
      fi
    else
      log "${NODE_SERVICE_HOST}:SERVICE NOT CREATED"
    fi
  done

  if [ "${RECONCILE_MASTER_IF_DOWN}" == "true" ]; then
    if need_to_poll ; then
      poll_exit_code=0
      poll_for_master "${SERVICE_HOSTS}" || poll_exit_code=$?
      case ${poll_exit_code} in
      5)
        # We should be master, no other nodes running...
        log "Bootstrapping recovery as MASTER..."
        WSREP_CLUSTER_ADDRESS="gcomm://"
        ;;
      0)
        log "Bootstrapping recovery with peers..."
        WSREP_CLUSTER_ADDRESS="gcomm://${RECOVERY_HOSTS}"
        ;;
      *)
        log "Error running polling client:${poll_exit_code}"
        exit 1
        ;;
      esac
    else
      log "Peers detected or only master, NOT polling..."
    fi
  fi
}

# if NUM_NODES not passed, default to 3
if [ -z "$NUM_NODES" ]; then
  NUM_NODES=3
fi

if [ "${1:0:1}" = '-' ]; then
  set -- mysqld "$@"
fi

# Adds the correct permissions BEFORE detecting directories etc...
chown -R mysql:mysql /var/log/mysql
chown -R mysql:mysql ${DATADIR}

if [ "${WAIT_FOR_SECRETS}" == "true" ]; then
  for file in ${WAIT_FOR_SECRETS_FILES}; do
    file_path=${SECRETS_PATH}/${file}
    log "Waiting for secrets file ${file_path}"
    while [ ! -f ${file_path} ]; do
      sleep 5
    done
  done
  log "Secrets present, continuing..."
fi

# Set the defaults from files...
WSREP_SST_PASSWORD=${WSREP_SST_PASSWORD:-$(cat ${SECRETS_PATH}/wsrep-sst-password)}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-$(cat ${SECRETS_PATH}/mysql-root-password)}
if [ ${MYSQL_USER} ]; then
  MYSQL_PASSWORD=${MYSQL_PASSWORD:-$(cat ${SECRETS_PATH}/mysql-password)}
fi
# if the command passed is 'mysqld' via CMD, then begin processing. 
if [ "$1" = 'mysqld' ]; then
  # only check if system tables not created from mysql_install_db and permissions
  # set with initial SQL script before proceding to build SQL script
  if [ -d "${DATADIR}/mysql" ]; then
    log "Data found, no mysql install required."
  else
    log "New node, no data at:${DATADIR}/mysql"

    # New node, no recovery process required...
    RECONCILE_MASTER_IF_DOWN=false
    # New node, don't try and contact (other nodes could be down)...
    CONTACT_PEERS_FOR_WSREP=false

    # fail if user didn't supply a root password
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ]; then
      log 'error: database is uninitialized and MYSQL_ROOT_PASSWORD not set'
      log '  Did you forget to add -e MYSQL_ROOT_PASSWORD=... ?'
      exit 1
    fi

    # mysql_install_db installs system tables
    log 'Running mysql_install_db ...'
    mysql_install_db --datadir="$DATADIR"
    log 'Finished mysql_install_db'

    # this script will be run once when MySQL first starts to set up
    # prior to creating system tables and will ensure proper user permissions 
    tempSqlFile='/tmp/mysql-first-time.sql'
    cat > "$tempSqlFile" <<-EOSQL
DELETE FROM mysql.user;
FLUSH PRIVILEGES;
COMMIT;
GRANT ALL ON *.* TO 'root'@'%' identified by '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION ;
EOSQL
    
    if [ "$MYSQL_DATABASE" ]; then
      echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> "$tempSqlFile"
    fi
    
    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
      echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> "$tempSqlFile"
      
      if [ "$MYSQL_DATABASE" ]; then
        echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> "$tempSqlFile"
      fi
    fi

    # Add SST (Single State Transfer) user if Clustering is turned on
    if [ -n "$GALERA_CLUSTER" ]; then
      # this is the Single State Transfer user (SST, initial dump or xtrabackup user)
      WSREP_SST_USER=${WSREP_SST_USER:-"sst"}
      if [ -z "$WSREP_SST_PASSWORD" ]; then
        log 'error: Galera cluster is enabled and WSREP_SST_PASSWORD is not set'
        log '  Did you forget to add -e WSREP_SST__PASSWORD=... ?'
        exit 1
      fi
      # add single state transfer (SST) user privileges
      echo "CREATE USER '${WSREP_SST_USER}'@'localhost' IDENTIFIED BY '${WSREP_SST_PASSWORD}';" >> "$tempSqlFile"
      echo "GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${WSREP_SST_USER}'@'localhost';" >> "$tempSqlFile"
    fi

    echo 'FLUSH PRIVILEGES ;' >> "$tempSqlFile"
    echo 'COMMIT;' >> "$tempSqlFile"
    # Without this being run on any slave, the users table has a permanent lock as is marked crashed.
    # A crashed mysql.user table will prevent logins after a restart.
    echo 'USE mysql;' >> "$tempSqlFile"
    echo 'CHECK TABLE `user` FAST QUICK;' >> "$tempSqlFile"

    # Add the SQL file to mysqld's command line args
    set -- "$@" --init-file="$tempSqlFile"
  fi
  
  chown -R mysql:mysql "$DATADIR"
fi

# if cluster is turned on, then procede to build cluster setting strings
# that will be interpolated into the config files
if [ -n "$GALERA_CLUSTER" ]; then
  # this is the Single State Transfer user (SST, initial dump or xtrabackup user)
  WSREP_SST_USER=${WSREP_SST_USER:-"sst"}
  if [ -z "$WSREP_SST_PASSWORD" ]; then
    log 'error: database is uninitialized and WSREP_SST_PASSWORD not set'
    log '  Did you forget to add -e WSREP_SST_PASSWORD=xxx ?'
    exit 1
  fi

  # user/password for SST user
  sed -i -e "s|^wsrep_sst_auth=sstuser:changethis|wsrep_sst_auth=${WSREP_SST_USER}:${WSREP_SST_PASSWORD}|" \
    ${CONF_D}/cluster.cnf

  # set nodes own address
  WSREP_NODE_ADDRESS=`ip addr show | grep -E '^[ ]*inet' | grep -m1 global | awk '{ print $2 }' | sed -e 's/\/.*//'`
  if [ -n "$WSREP_NODE_ADDRESS" ]; then
    sed -i -e "s|^wsrep_node_address=.*$|wsrep_node_address=${WSREP_NODE_ADDRESS}|" ${CONF_D}/cluster.cnf
  fi
  
  detect_services_and_set_wsrep
  log "WSREP=${WSREP_CLUSTER_ADDRESS}"

  # WSREP_CLUSTER_ADDRESS is now complete and will be interpolated into the
  # cluster address string (wsrep_cluster_address) in the cluster
  # configuration file, cluster.cnf
  if [ -n "$WSREP_CLUSTER_ADDRESS" ]; then
    CURRENT_CLUSTER_LINE=$(grep "wsrep_cluster_address=gcomm://" ${CONF_D}/cluster.cnf | awk -F= '{ print $2 }')
    if [[ "${CURRENT_CLUSTER_LINE}" != "${WSREP_CLUSTER_ADDRESS}" ]]; then
      log "Setting cluster address to ${WSREP_CLUSTER_ADDRESS}"
      sed -i -e "s|^wsrep_cluster_address=gcomm://.*$|wsrep_cluster_address=${WSREP_CLUSTER_ADDRESS}|" ${CONF_D}/cluster.cnf
    else
      log "Cluster address already set to ${WSREP_CLUSTER_ADDRESS}, leaving as is."
    fi
  fi
fi

# random server ID needed (IF data not preserved)
if [ -f "${DATADIR}/serverid" ]; then
  SERVER_ID=$(cat "${DATADIR}/serverid")
else
  SERVER_ID=${RANDOM}
  echo ${SERVER_ID}>${DATADIR}/serverid
fi

sed -i -e "s/^server\-id=.*$/server-id=${SERVER_ID}/" ${CONF_FILE}

echo "[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
">~/.my.cnf

chmod 0600 ~/.my.cnf

# finally, start mysql 
exec "$@"
