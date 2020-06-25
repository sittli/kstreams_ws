#!/bin/bash
set -x

################################################################################
# Overview
################################################################################
#
# Delete Kafka cluster and environment if start.sh exited prematurely
#
################################################################################

# Source library
. ./helper.sh

check_ccloud_version 1.0.0 || exit 1
check_timeout || exit 1
check_mvn || exit 1
check_expect || exit 1
check_jq || exit 1

#
# SITTA specifics
#
XX_CCLOUD_PASSWORD=
XX_CLOUD_EMAIL=
DEMO_TOPIC_PREFIX=geo
export DEMO_ENVIRONMENT_NAME="sitta-demo"
export DEMO_CLUSTER_NAME="sitta-kafka-cluster"

# other config
# CLIENT_CONFIG="/tmp/client.config"


##################################################
# Read URL, EMAIL, PASSWORD from command line arguments
#
#  Rudimentary argument processing and must be in order:
#    <url to cloud> <cloud email> <cloud password>
##################################################
URL=$1
EMAIL=$2
PASSWORD=$3
if [[ -z "$URL" ]]; then
  read -s -p "Cloud cluster: " URL
  echo ""
fi
if [[ -z "$EMAIL" ]]; then
  read -s -p "Cloud user email: " EMAIL
  echo ""
fi
if [[ -z "$PASSWORD" ]]; then
  read -s -p "Cloud user password: " PASSWORD
  echo ""
fi


##################################################
# Log in to Confluent Cloud
##################################################

echo -e "\n# Login"
OUTPUT=$(
expect <<END
  log_user 1
  spawn ccloud login --url $URL
  expect "Email: "
  send "$EMAIL\r";
  expect "Password: "
  send "$PASSWORD\r";
  expect "Logged in as "
  set result $expect_out(buffer)
END
)
echo "$OUTPUT"
if [[ ! "$OUTPUT" =~ "Logged in as" ]]; then
  echo "Failed to log into your cluster.  Please check all parameters and run again"
  exit 1
fi

ENVIRONMENT=`ccloud environment list -ojson | jq -r '.[] | select(.name == env.DEMO_ENVIRONMENT_NAME)' | jq -r .id`
echo $ENVIRONMENT
if [[ -z "$ENVIRONMENT" ]]; then
  echo "Environment does not exist. Please troubleshoot and try again."
  exit 1
fi
ccloud environment use $ENVIRONMENT

#CLUSTER=$(ccloud kafka cluster list | grep $CLUSTER_NAME | awk '{print $1;}')
CLUSTER=`ccloud kafka cluster list -ojson | jq -r '.[] | select(.name == env.DEMO_CLUSTER_NAME)' | jq -r .id`
if [[ -z "$CLUSTER" ]]; then
  echo "Cluster does not exist. Please troubleshoot and try again."
  exit 1
fi
ccloud kafka cluster use $CLUSTER



##################################################
# Cleanup
# - Delete the Kafka topics, Kafka cluster, environment, and the log files
##################################################

echo -e "\n# Cleanup: delete topics, kafka cluster, environment"
# connect topics: connect-configs connect-offsets connect-status
for t in geo_eventdata geo_eventdata_lookup geo_eventdata_response geo_eventdata_store geo_eventdata_pending_store; do
  if ccloud kafka topic describe $t &>/dev/null; then
    echo "ccloud kafka topic delete $t"
    ccloud kafka topic delete $t
  fi
done

if [[ ! -z "$CLUSTER" ]]; then
  echo "ccloud kafka cluster delete $CLUSTER"
  ccloud kafka cluster delete $CLUSTER 1>/dev/null
fi

if [[ ! -z "$ENVIRONMENT" ]]; then
  echo "ccloud environment delete $ENVIRONMENT"
  ccloud environment delete $ENVIRONMENT 1>/dev/null
fi

# rm -f "$CLIENT_CONFIG"

export DEMO_ENVIRONMENT_NAME=
export DEMO_CLUSTER_NAME=

