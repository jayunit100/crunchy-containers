#!/bin/bash  -x

# Copyright 2015 Crunchy Data Solutions, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#export OSE_HOST=openshift.default.svc.cluster.local

function trap_sigterm() {
	echo "doing trap logic..."  >> /tmp/trap.out
	shutdownrequested=true
}

trap 'trap_sigterm' SIGINT SIGTERM
shutdownrequested=false

function ose_hack() {
	export USER_ID=$(id -u)
	export GROUP_ID=$(id -g)
	envsubst < /opt/cpm/conf/passwd.template > /tmp/passwd
	export LD_PRELOAD=/usr/lib64/libnss_wrapper.so
	export NSS_WRAPPER_PASSWD=/tmp/passwd
	export NSS_WRAPPER_GROUP=/etc/group
}



if [ ! -v SLEEP_TIME ]; then
	SLEEP_TIME=10
fi
if [ ! -v WAIT_TIME ]; then
	WAIT_TIME=40
fi
if [ ! -v MAX_FAILURES ]; then
	MAX_FAILURES=3
fi
echo "SLEEP_TIME is set to " $SLEEP_TIME
echo "WAIT_TIME is set to " $WAIT_TIME
echo "MAX_FAILURES is set to " $MAX_FAILURES

export PG_MASTER_SERVICE=$PG_MASTER_SERVICE
export PG_REPLICA_SERVICE=$PG_REPLICA_SERVICE
export PG_MASTER_PORT=$PG_MASTER_PORT
export PG_MASTER_USER=$PG_MASTER_USER
export PG_USER=$PG_USER
export PG_DATABASE=$PG_DATABASE

if [ -d /usr/pgsql-9.6 ]; then
        export PGROOT=/usr/pgsql-9.6
elif [ -d /usr/pgsql-9.5 ]; then
        export PGROOT=/usr/pgsql-9.5
elif [ -d /usr/pgsql-9.4 ]; then
        export PGROOT=/usr/pgsql-9.4
else
        export PGROOT=/usr/pgsql-9.3
fi

echo "setting PGROOT to " $PGROOT

export PATH=$PATH:/opt/cpm/bin:$PGROOT/bin

ose_hack

function failover() {
	# Perform watch pre-hook
	exec_pre_hook

	# Perform failover
	if [[ -v KUBE_PROJECT ]]; then
		echo "kube failover ....."
		kube_failover
	elif [[ -v OSE_PROJECT ]]; then
		echo "openshift failover ....."
		ose_failover
	else
		echo "standalone failover....."
		standalone_failover
	fi

	# Perform watch post-hook
	exec_post_hook
}

function standalone_failover() {
	echo "standalone failover is called"

	# env var is required to talk to older docker
	# server using a more recent docker client
	export DOCKER_API_VERSION=1.20
	echo "creating the trigger file on " $PG_REPLICA_SERVICE
	docker exec $PG_REPLICA_SERVICE touch /tmp/pg-failover-trigger
	echo "exiting after the failover has been triggered..."
	exit 0
}

function kube_failover() {

	export TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
	#oc login https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT --insecure-skip-tls-verify=true --token="$TOKEN"
	#oc project $OSE_PROJECT
	echo "performing failover..."

	TRIGGERSLAVES=`kubectl --token=$TOKEN get pod --selector=name=$PG_REPLICA_SERVICE,slavetype=trigger --no-headers | cut -f1 -d' '`
	echo $TRIGGERSLAVES " is TRIGGERSLAVES"
	if [ "$TRIGGERSLAVES" = "" ]; then
		echo "no trigger slaves found...using any slave"
		SLAVES=`kubectl --token=$TOKEN get pod --selector=name=$PG_REPLICA_SERVICE --no-headers | cut -f1 -d' '`
	else
		echo "trigger slaves found!"
		SLAVES=$TRIGGERSLAVES
	fi

	declare -a arr=($SLAVES)
	if [[ -v REPLICA_TO_TRIGGER_LABEL ]]; then
		echo "trigger to specific replica... using REPLICA_TO_TRIGGER_LABEL environment variable"
		targetslave=$REPLICA_TO_TRIGGER_LABEL
	else
		targetslave=${arr[0]}
	fi

	for i in  "${arr[@]}"
	do
		if [ "$targetslave" = $i ] ; then
			echo "going to trigger failover on slave:" $i
			kubectl --token=$TOKEN exec $i touch /tmp/pg-failover-trigger
			echo "sleeping WAIT_TIME to give failover a chance before setting label"
			sleep $WAIT_TIME
			echo "changing label of slave to " $PG_MASTER_SERVICE
			kubectl --token=$TOKEN label --overwrite=true pod $i name=$PG_MASTER_SERVICE
		fi
	done
	echo "failover completed @ " `date`
}
function ose_failover() {

	TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
	oc login https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT --insecure-skip-tls-verify=true --token="$TOKEN"
	oc project $OSE_PROJECT
	echo "performing failover..."
#	echo "deleting master service to block slaves..."
#	oc get service $PG_MASTER_SERVICE -o json > /tmp/master-service.json
#	oc delete service $PG_MASTER_SERVICE
	echo "sleeping for 10 to give slaves chance to halt..."
	sleep 10

	TRIGGERSLAVES=`oc get pod --selector=name=$PG_REPLICA_SERVICE,slavetype=trigger --no-headers | cut -f1 -d' '`
	echo $TRIGGERSLAVES " is TRIGGERSLAVES"
	if [ "$TRIGGERSLAVES" = "" ]; then
		echo "no trigger slaves found...using any slave"
		SLAVES=`oc get pod --selector=name=$PG_REPLICA_SERVICE --no-headers | cut -f1 -d' '`
	else
		echo "trigger slaves found!"
		SLAVES=$TRIGGERSLAVES
	fi

	declare -a arr=($SLAVES)
	if [[ -v REPLICA_TO_TRIGGER_LABEL ]]; then
		echo "trigger to specific replica... using REPLICA_TO_TRIGGER_LABEL environment variable"
		targetslave=$REPLICA_TO_TRIGGER_LABEL
	else
		targetslave=${arr[0]}
	fi

	for i in  "${arr[@]}"
	do
		if [ "$targetslave" = $i ] ; then
			echo "going to trigger failover on slave:" $i
			oc exec $i touch /tmp/pg-failover-trigger
			echo "sleeping WAIT_TIME to give failover a chance before setting label"
			sleep $WAIT_TIME
			echo "changing label of slave to " $PG_MASTER_SERVICE
			oc label --overwrite=true pod $i name=$PG_MASTER_SERVICE
		fi
	done
	echo "failover completed @ " `date`
}

# Execute 'watch' pre-hook.
function exec_pre_hook() {
	echo HOOK: $WATCH_PRE_HOOK
	if [ ! -z $WATCH_PRE_HOOK ] &&
	   [ -e $WATCH_PRE_HOOK ]; then
		/bin/bash $WATCH_PRE_HOOK
	fi
}

# Execute 'watch' post-hook.
function exec_post_hook() {
	if [ ! -z $WATCH_POST_HOOK ] &&
	   [ -e $WATCH_POST_HOOK ]; then
		/bin/bash $WATCH_POST_HOOK
	fi
}

FAILURES=0
while true; do
	if [ "$shutdownrequested" = true ] ; then
		echo "doing shutdown..."
		exit 0
	fi
	sleep $SLEEP_TIME
	pg_isready  --dbname=$PG_DATABASE --host=$PG_MASTER_SERVICE --port=$PG_MASTER_PORT --username=$PG_MASTER_USER
	if [ $? -eq 0 ]
	then
		echo "Successfully reached master @ " `date`
	else
		echo "Could not reach master @ " `date`
		FAILURES=$[$FAILURES+1]
		if [[ $FAILURES -lt $MAX_FAILURES ]]; then
			continue
		fi
		echo "Maximum failures reached"
		failover
		FAILURES=0
	fi
done
