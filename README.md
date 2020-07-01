# KStreams Pattern 'Progressive Cache'
Demo solution for a KStreams pattern 'Progressive Cache' or 'Progressive State Enrichment'.
## Motivation
In an ideal world, master or reference data is upfront made available as a materialized view to an event streaming application.\
However there are use cases, where it is not feasible by volume, effort or cost to preload all data.\
In this case, a 'progressive cache', that evolves over time, is a useful pattern.\
The progressive cache should be implemented with streaming best practices in mind.
## Sequence Diagram
TBD: embed sequence diagram
## What does the demo do?
* A script will generate a Confluent Cloud environment / cluster / topics / ACL / service accounts / schema registry / schemas plus various shell scripts
* A Java streaming service (S) enriches events either directly or indirectly
* A Java microservice (MS) with inbound/outbound topics (async interface) invokes an external service
* The shell scripts allow to publish or consume data from different topics (initial, final, intermediary)
## Prerequisites
The following tools must exist locally, before you can proceed
* JDK 8 or higher
* ccloud
* Maven
* kafkacat
* kafka-avro-console-producer command line tool (part of Apache Kafka)
* text editor
* access to a Confluent Cloud instance (username and password)
* a valid key for [Google Maps API](https://developers.google.com/maps/documentation/geocoding/get-api-key)
## Establish Infrastructure
* (Optional) Adjust the two default settings in the initial section of the script ```start.sh```\
E.g. 
```
DEMO_ENVIRONMENT_NAME="sitta-demo"
DEMO_CLUSTER_NAME="sitta-kafka-cluster"
```
These are the names for the environment and the cluster that will get created.
Make sure that the following env vars are not set 
```
XX_CCLOUD_EMAIL
XX_CCLOUD_PASSWORD
```
### Execute 
```
./start.sh <CC_URL> <CC_USER_KEY> <CC_USER_SECRET>
```
e.g.
```
./start.sh https://confluent.cloud andreas@confluent.io 9bLC90q6c1Yl!TYNXUk*
```
Alternatively you can start without arguments and respond to the prompt for the various pieces of information.\
Note, that you can ignore a line that reads like
```
./helper.sh: line 7: /some/directory/kstreams_ws/config.env
```
At one point you will see a line like 
```
Error: Command not yet available for non -Kafka cluster resources.
```
Unfortunately you have to manually provide again the key/secret for the Service Registry that were just created by the script.\
**You should do this only once you are prompted.**\
To facilitate that, both key and secret are written to standard output a few lines above. Just copy from there.
It will look something like this.
```
Schema Registry key/secret QALNTZPXFBHT3M3W Nu1r22mYCqu2+AosfiaFjLeMXgwA++VwEQVKM2V257gNxgfoPCHQn9/KbdV23Q8+
Error: Command not yet available for non -Kafka cluster resources.

# Wait 90 seconds for the SR credentials to propagate
Enter your Schema Registry API Key:
QALNTZPXFBHT3M3W
Enter your Schema Registry API Secret:
Nu1r22mYCqu2+AosfiaFjLeMXgwA++VwEQVKM2V257gNxgfoPCHQn9/KbdV23Q8+
```
### Validate Infrastructure
* Environment, Cluster, Topics
Login to CC and check the availability of the cluster in the specific environment.\
Check the existence of topics.
* 

## Build Java Client Apps
* Edit the file ```GeoEventApp.java``` and provide your GoogleMaps API key. E.g.
```
static String GOOGLE_MAPS_API_KEY = "9bLC90q6c1Yl!TYNXUk*";
```
* Build the jar like
```
cd geoevent
mvn clean package
cd ..
```
This will create a jar named ```geoevent-jar-with-dependencies.jar```

### Start Microservice
* Execute similar to 
```
java -cp <YOUR_DIRECTORY>/streams_ws/geoevent/target/geoevent-jar-with-dependencies.jar com.github.sittli.geoevent.GeoEventApp
```
### Start Streaming App
```
java -cp <YOUR_DIRECTORY>/kstreams_ws/geoevent/target/geoevent-jar-with-dependencies.jar com.github.sittli.geoevent.GeoStreamApp
```
### Start Consumer(s)
There are multiple kafkacat consumers to various topics that are wrapped in generated shell scripts that can be found in ```./scripts```
You can start the listener for the final output topic 
```
./scripts/geo_eventdata_final.sh
```
### Start Producer
```
./scripts/geo_eventdata_produce.sh
```
You need to provide JSON data (that will be serialized as Avro) like
```
{"address": "Rathausmarkt 1, 20095 Hamburg", "eventtype": "fire"}
{"address": "Rathausmarkt 4, 20095 Hamburg", "eventtype": "storm"}
{"address": "Rathausmarkt 6, 20095 Hamburg", "eventtype": "taifun"}
```
You should be able to provide any (german) address that you want.\
(Note, that currently every address is postfixed with 'Germany', before invoking the GoogleMaps API, so you might want to change the relevant code here as well, if you intend to use arbitrary addresses.)\
The eventtype has no meaning and is just there to illustrate additional payload that needs to be pended as well.
## Observation
TBD
# Caveat / Enhancements / ToDo's
Unsorted list of things that should be improved
* The Progressive Cache table should be a Ktable instead of a GlobalKtable
* The Progressive Cache should implement aging (e.g. by punctuation)
* The Pending Cache should be cleaned of old requests
* The topics geo_eventdata_pending_store and geo_eventdata_store are not the actual changelog topics of the corresponding tables and could be eliminated
* The generated scripts have a dependency on CWD
