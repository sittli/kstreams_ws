# KStreams Workshop
Demo solution for a pattern 'Progressive State Enrichment'
## Motivation
TBD
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
* Execute 
```
./start.sh <CC_URL> <CC_USER_KEY> <CC_USER_SECRET>
```
e.g.
```
./start.sh https://confluent.cloud andreas@confluent.io 349wojwe2v"L:r*f;jrk
```
Alternatively you can start without arguments and respond to the prompt for the various pieces of information.\
Note, that you can ignore a line that reads like
```
./helper.sh: line 7: /some/directort/kstreams_ws/config.env
```
At one point you will see a line like 
```
Error: Command not yet available for non -Kafka cluster resources.
```
Unfortunately you have to manually provide again the key/secret for the Service Registry that were just created by the script.\
To facilitate that, they are written to output a few lines above. Just copy from there.
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
## Build Java Client Apps
* Edit the file ```GeoEvent.java``` and provide your GoogleMaps API key. E.g.
```
static String GOOGLE_MAPS_API_KEY = "asdfkl;3i3qiWKLE05_we;lkA(*WE";
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
### Start Consumer
There are multiple kafkacat consumers to various topics that are wrapped in shell scripts that can be found in ```./scripts```
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
You should be able to provide any address that you want.\
(Note, that currently every address is postfixed with 'Germany', so you might want to change the code here as well.)\
The eventtype has no meaning and is just there to illustrate additional payload.

