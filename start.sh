#!/bin/bash
# set -x

################################################################################
# Overview
################################################################################
#
# See README.md for usage and disclaimers
#
################################################################################

# Source library
. ./helper.sh

check_ccloud_version 1.0.0 || exit 1
check_timeout || exit 1
check_mvn || exit 1
check_expect || exit 1
check_jq || exit 1
# check_docker || exit 1

#
# SITTA specifics
#
XX_CCLOUD_PASSWORD=
XX_CLOUD_EMAIL=
DEMO_TOPIC_PREFIX=geo
DEMO_SCHEMA_DIR=./geoevent/src/main/resources/avro/com.github.sittli.geoevent
DEMO_SCRIPT_DIR=./scripts
DEMO_ENVIRONMENT_NAME="sitta-demo"
DEMO_CLUSTER_NAME="sitta-kafka-cluster"

# other config
CLIENT_CONFIG="$DEMO_SCRIPT_DIR/client.config"


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


##################################################
# Create a new environment and specify it as the default
##################################################
function create_env() {
ENVIRONMENT_NAME=$DEMO_ENVIRONMENT_NAME
echo -e "\n# Create and specify active environment"
echo "ccloud environment create $ENVIRONMENT_NAME"
ccloud environment create $ENVIRONMENT_NAME
if [[ $? != 0 ]]; then
  echo "Failed to create environment $ENVIRONMENT_NAME. Please troubleshoot and run again"
  exit 1
fi
echo "ccloud environment list | grep $ENVIRONMENT_NAME"
ccloud environment list | grep $ENVIRONMENT_NAME
ENVIRONMENT=$(ccloud environment list | grep $ENVIRONMENT_NAME | awk '{print $1;}')

echo -e "\n# Specify active environment that was just created"
echo "ccloud environment use $ENVIRONMENT"
ccloud environment use $ENVIRONMENT
return 0
}

##################################################
# Create a new Kafka cluster and specify it as the default
##################################################
function create_cluster() {
CLUSTER_NAME=$DEMO_CLUSTER_NAME
echo -e "\n# Create and specify active Kafka cluster"
echo "ccloud kafka cluster create $CLUSTER_NAME --cloud gcp --region us-central1 --availability single-zone --type basic"
OUTPUT=$(ccloud kafka cluster create $CLUSTER_NAME --cloud gcp --region us-central1 --availability single-zone --type basic)
status=$?
echo "$OUTPUT"
if [[ $status != 0 ]]; then
  echo "Failed to create Kafka cluster $CLUSTER_NAME. Please troubleshoot and run again"
  exit 1
fi
CLUSTER=$(echo "$OUTPUT" | grep '| Id' | awk '{print $4;}')

echo -e "\n# Specify active Kafka cluster that was just created"
echo "ccloud kafka cluster use $CLUSTER"
ccloud kafka cluster use $CLUSTER
BOOTSTRAP_SERVERS=$(echo "$OUTPUT" | grep "Endpoint" | grep SASL_SSL | awk '{print $4;}' | cut -c 12-)
return 0
}


##################################################
# Create a user key/secret pair and specify it as the default
##################################################
function create_user_api_key() {
echo -e "\n# Create API key for $EMAIL"
echo "ccloud api-key create --description \"Demo credentials for $EMAIL\" --resource $CLUSTER"
OUTPUT=$(ccloud api-key create --description "Demo credentials for $EMAIL" --resource $CLUSTER)
status=$?
echo "$OUTPUT"
if [[ $status != 0 ]]; then
  echo "Failed to create an API key. Please troubleshoot and run again"
  exit 1
fi
API_KEY=$(echo "$OUTPUT" | grep '| API Key' | awk '{print $5;}')

echo -e "\n# Specify active API key that was just created"
echo "ccloud api-key use $API_KEY --resource $CLUSTER"
ccloud api-key use $API_KEY --resource $CLUSTER

echo -e "\n# Wait 90 seconds for the user credentials to propagate"
sleep 90
return 0
}


##################################################
# Create a service account key/secret pair
# - A service account represents an application, and the service account name must be globally unique
##################################################

function init_service_account() {
echo -e "\n# Create a new service account"
RANDOM_NUM=$((1 + RANDOM % 1000000))
SERVICE_NAME="sitta-demo-app-$RANDOM_NUM"
echo "ccloud service-account create $SERVICE_NAME --description $SERVICE_NAME"
ccloud service-account create $SERVICE_NAME --description $SERVICE_NAME || true
SERVICE_ACCOUNT_ID=$(ccloud service-account list | grep $SERVICE_NAME | awk '{print $1;}')

echo -e "\n# Create an API key and secret for the new service account"
echo "ccloud api-key create --service-account $SERVICE_ACCOUNT_ID --resource $CLUSTER"
OUTPUT=$(ccloud api-key create --service-account $SERVICE_ACCOUNT_ID --resource $CLUSTER)
echo "$OUTPUT"
API_KEY_SA=$(echo "$OUTPUT" | grep '| API Key' | awk '{print $5;}')
API_SECRET_SA=$(echo "$OUTPUT" | grep '| Secret' | awk '{print $4;}')

echo -e "\n# Create a local configuration file $CLIENT_CONFIG with Confluent Cloud connection information with the newly created API key and secret"
cat <<EOF > $CLIENT_CONFIG
ssl.endpoint.identification.algorithm=https
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
request.timeout.ms=20000
retry.backoff.ms=500
auto.register.schemas=false
bootstrap.servers=${BOOTSTRAP_SERVERS}
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username\="${API_KEY_SA}" password\="${API_SECRET_SA}";
EOF
cat $CLIENT_CONFIG

echo -e "\n# Wait 90 seconds for the service account credentials to propagate"
sleep 90
}

# prefix is before the first dash
# PREFIX=${TOPIC2/%-*/}
# ccloud kafka acl create --allow --service-account $SERVICE_ACCOUNT_ID --operation CREATE --topic $PREFIX --prefix


# init microservice
# 
function init_microservice() {
KSTREAMS_DEMO_T_GEO_REQUEST="${DEMO_TOPIC_PREFIX}_eventdata_lookup"
KSTREAMS_DEMO_T_GEO_RESPONSE="${DEMO_TOPIC_PREFIX}_eventdata_response"
KSTREAMS_DEMO_CG_MS="${DEMO_TOPIC_PREFIX}-lookup-ms"

ccloud kafka topic create $KSTREAMS_DEMO_T_GEO_REQUEST --partitions 1
echo "Created topic ${KSTREAMS_DEMO_T_GEO_REQUEST} " $?
ccloud kafka topic create $KSTREAMS_DEMO_T_GEO_RESPONSE --partitions 1
echo "Created topic ${KSTREAMS_DEMO_T_GEO_RESPONSE} " $?
ccloud kafka acl create --allow --operation READ --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --consumer-group $KSTREAMS_DEMO_CG_MS
ccloud kafka acl create --allow --operation WRITE --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --consumer-group $KSTREAMS_DEMO_CG_MS
ccloud kafka acl create --allow --operation DESCRIBE --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --consumer-group $KSTREAMS_DEMO_CG_MS
if [[ $? != 0 ]]; then
  echo "Failed to init microservice."
  exit 1
fi
return 0
}

# init streaming app
#
function init_streaming_app() {
  KSTREAMS_DEMO_T_INITIAL="${DEMO_TOPIC_PREFIX}_eventdata"
  KSTREAMS_DEMO_S_ACTIVE="${DEMO_TOPIC_PREFIX}_eventdata_store"
  KSTREAMS_DEMO_S_PENDING="${DEMO_TOPIC_PREFIX}_eventdata_pending_store"
  KSTREAMS_DEMO_T_FINAL="${DEMO_TOPIC_PREFIX}_eventdata_enriched"
  KSTREAMS_DEMO_CG_APP="${DEMO_TOPIC_PREFIX}-streams-app"

  ccloud kafka topic create $KSTREAMS_DEMO_T_INITIAL --partitions 1
  echo "Created topic ${KSTREAMS_DEMO_T_INITIAL} " $?
  ccloud kafka topic create $KSTREAMS_DEMO_T_FINAL --partitions 1
  echo "Created topic ${KSTREAMS_DEMO_T_FINAL} " $?
  ccloud kafka topic create $KSTREAMS_DEMO_S_ACTIVE --partitions 1 --config cleanup.policy=compact
  echo "Created topic ${KSTREAMS_DEMO_S_ACTIVE} " $?
  ccloud kafka topic create $KSTREAMS_DEMO_S_PENDING --partitions 1 --config cleanup.policy=compact
  echo "Created topic ${KSTREAMS_DEMO_S_PENDING} " $?
  ccloud kafka acl create --allow --operation READ --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --consumer-group $KSTREAMS_DEMO_CG_APP
  #ccloud kafka acl create --allow --operation WRITE --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --consumer-group $KSTREAMS_DEMO_CG_APP
  ccloud kafka acl create --allow --operation DESCRIBE --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --consumer-group $KSTREAMS_DEMO_CG_APP
  #ccloud kafka acl create --allow --operation CREATE --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --consumer-group $KSTREAMS_DEMO_CG_APP
  # changelog topic creation
  ccloud kafka acl create --allow --operation CREATE --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --topic $KSTREAMS_DEMO_CG_APP --prefix
  if [[ $? != 0 ]]; then
    echo "Failed to init streaming app."
    exit 1
  fi
  return 0
}


function init_application() {
  KSTREAMS_DEMO_SVC_ACCT_ID=$SERVICE_ACCOUNT_ID
  CC_CLUSTER_ID=$CLUSTER
  init_microservice || exit 1
  init_streaming_app || exit 1
# prefix entitlements
  ccloud kafka acl create --allow --operation READ --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --topic $DEMO_TOPIC_PREFIX --prefix
  ccloud kafka acl create --allow --operation WRITE --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --topic $DEMO_TOPIC_PREFIX --prefix
  ccloud kafka acl create --allow --operation DESCRIBE --service-account $KSTREAMS_DEMO_SVC_ACCT_ID --cluster $CC_CLUSTER_ID --topic $DEMO_TOPIC_PREFIX --prefix

}

# init schema registry
#
function init_SR() {
  ccloud schema-registry cluster enable --cloud gcp --geo us
  if [[ $? != 0 ]]; then
    echo "Failed to enable schema-registry in Confluent Cloud. Please troubleshoot/cleanup and run again."
    exit 1
  fi
  SR_URL=`ccloud schema-registry cluster describe -ojson | jq -r .endpoint_url`
  # remove leading 'https://' (8 chars)
  SR_URL_STRIPPED=`echo "${SR_URL:8}"`
  SR_CLUSTER_ID=`ccloud schema-registry cluster describe -ojson | jq -r .cluster_id`
  if [ -z "$SR_URL" ]; then 
    echo "SR_URL is not set. Please troubleshoot/cleanup and run again."
    exit 1 
  fi
  if [ -z "$SR_CLUSTER_ID" ]; then 
    echo "SR_CLUSTER_ID is not set. Please troubleshoot/cleanup and run again."
    exit 1 
  fi
  SR_OUTPUT=`ccloud api-key create --description "SR Demo credentials for $EMAIL" --resource $SR_CLUSTER_ID -ojson`
  status=$?
 if [[ $status != 0 ]]; then
  echo "Failed to create SR API key. Please troubleshoot/cleanup and run again."
  exit 1
fi
  SR_API_KEY=`echo $SR_OUTPUT | jq -r .key`
  SR_API_SECRET=`echo $SR_OUTPUT | jq -r .secret`
  # replace all forward slashes with %2F (required for kafkacat consume command lines)
  SR_API_KEY_ENCODED=`echo $SR_API_KEY | sed 's|\/|%2F|g'`
  SR_API_SECRET_ENCODED=`echo $SR_API_SECRET | sed 's|\/|%2F|g'`
  echo "Schema Registry key/secret ${SR_API_KEY} ${SR_API_SECRET}"
  # persist SR key/secret to config.json in order to avoid prompt to enter SR key/secret
  # fails with 'Error: Command not yet available for non -Kafka cluster resources.'
  # todo: try instead with Kafka cluster ID
  ccloud api-key store $SR_API_KEY $SR_API_SECRET --resource $SR_CLUSTER_ID
  echo -e "\n# Wait 90 seconds for the SR credentials to propagate"
  sleep 90
# schema for microservice
  ccloud schema-registry schema create --subject geo_eventdata_lookup-value --schema $DEMO_SCHEMA_DIR/geodata_event_request.avsc
  ccloud schema-registry schema create --subject geo_eventdata_response-value --schema $DEMO_SCHEMA_DIR/geodata_event_response.avsc
# schema for streaming app
  ccloud schema-registry schema create --subject geo_eventdata-value --schema $DEMO_SCHEMA_DIR/geodata_event.avsc
  ccloud schema-registry schema create --subject geo_eventdata_store-value --schema $DEMO_SCHEMA_DIR/geodata_event_enriched.avsc
  ccloud schema-registry schema create --subject geo_eventdata_pending_store-value --schema $DEMO_SCHEMA_DIR/geodata_event_enriched.avsc
  ccloud schema-registry schema create --subject geo_eventdata_enriched-value --schema $DEMO_SCHEMA_DIR/geodata_event_enriched.avsc
  return 0
}

function update_client_config() {
cat <<EOF >> $CLIENT_CONFIG
schema.registry.url=${SR_URL}
schema.registry.basic.auth.user.info=${SR_API_KEY}:${SR_API_SECRET}
EOF
cat $CLIENT_CONFIG
}

function init_kafkacat_consume_script() {
  cat<< EOF > $DEMO_OUT_FILE
  #!/bin/bash
  kafkacat -b ${BOOTSTRAP_SERVERS} -C -X security.protocol=SASL_SSL -X sasl.mechanisms=PLAIN -X sasl.username=${API_KEY_SA} \
  -X sasl.password=${API_SECRET_SA} \
  -s value=avro -r https://${SR_API_KEY_ENCODED}:${SR_API_SECRET_ENCODED}@${SR_URL_STRIPPED} -t ${DEMO_TOPIC} -K ':' -o 1
EOF
}

function init_produce_script() {
  cat<< EOF > $DEMO_OUT_FILE
  #!/bin/bash
kafka-avro-console-producer --topic ${DEMO_TOPIC} --broker-list ${BOOTSTRAP_SERVERS} --producer.config ~/cnfl/proj/idea/sittli/geoevent/src/main/resources/producer-config.properties \
 --producer-property auto.register.schemas="false" --property schema.registry.url="${SR_URL}" --property basic.auth.credentials.source=USER_INFO \
 --property basic.auth.user.info="${SR_API_KEY}:${SR_API_SECRET}" \
 --property value.schema="$(< ~/cnfl/proj/idea/sittli/geoevent/src/main/resources/avro/com.github.sittli.geoevent/geodata_event.avsc)"
EOF
}

function init_scripts() {
  DEMO_OUT_FILE=$DEMO_SCRIPT_DIR/geo_eventdata_store.sh
  touch $DEMO_OUT_FILE
  DEMO_TOPIC=${KSTREAMS_DEMO_S_ACTIVE}
  init_kafkacat_consume_script || exit 1
  DEMO_OUT_FILE=$DEMO_SCRIPT_DIR/geo_eventdata_pending_store.sh
  touch $DEMO_OUT_FILE
  DEMO_TOPIC=${KSTREAMS_DEMO_S_PENDING}
  init_kafkacat_consume_script || exit 1
  DEMO_OUT_FILE=$DEMO_SCRIPT_DIR/geo_eventdata_lookup.sh
  touch $DEMO_OUT_FILE
  DEMO_TOPIC=${KSTREAMS_DEMO_T_GEO_REQUEST}
  init_kafkacat_consume_script || exit 1
  DEMO_OUT_FILE=$DEMO_SCRIPT_DIR/geo_eventdata_response.sh
  touch $DEMO_OUT_FILE
  DEMO_TOPIC=${KSTREAMS_DEMO_T_GEO_RESPONSE}
  init_kafkacat_consume_script || exit 1
  DEMO_OUT_FILE=$DEMO_SCRIPT_DIR/geo_eventdata_initial.sh
  touch $DEMO_OUT_FILE
  DEMO_TOPIC=${KSTREAMS_DEMO_T_INITIAL}
  init_kafkacat_consume_script || exit 1
  DEMO_OUT_FILE=$DEMO_SCRIPT_DIR/geo_eventdata_final.sh
  touch $DEMO_OUT_FILE
  DEMO_TOPIC=${KSTREAMS_DEMO_T_FINAL}
  init_kafkacat_consume_script || exit 1
  DEMO_OUT_FILE=$DEMO_SCRIPT_DIR/geo_eventdata_produce.sh
  touch $DEMO_OUT_FILE
  DEMO_TOPIC=${KSTREAMS_DEMO_T_INITIAL}
  init_produce_script || exit 1
  chmod u+x $DEMO_SCRIPT_DIR/*
  return 0
 }

#
# SITTA
# 

# infra wrapper
# 
function create_all() {
  create_env || exit 1
  create_cluster || exit 1
  create_user_api_key || exit 1
  init_service_account || exit 1
return 0
}
create_all || exit 1
echo "Environment: " + $ENVIRONMENT
echo "Cluster: " + $CLUSTER

# app wrapper
# 
init_application || exit 1
init_SR || exit 1
update_client_config || exit 1

# shell script wrapper 

init_scripts || exit 1

exit 0
