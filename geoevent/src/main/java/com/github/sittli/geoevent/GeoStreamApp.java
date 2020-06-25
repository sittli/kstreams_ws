package com.github.sittli.geoevent;

// import com.github.sittli.geodata.Event;
import com.github.sittli.geodata.Event;
import com.github.sittli.geodata.EventEnriched;
import com.github.sittli.geodata.EventRequest;
// import com.github.sittli.geodata.EventResponse;
import io.confluent.kafka.serializers.AbstractKafkaAvroSerDeConfig;
import io.confluent.kafka.streams.serdes.avro.SpecificAvroSerde;
import org.apache.avro.Schema;
import org.apache.avro.generic.GenericRecord;
import org.apache.kafka.clients.CommonClientConfigs;
import org.apache.kafka.clients.consumer.ConsumerConfig;
//import io.confluent.kafka.streams.serdes.avro.SpecificAvroSerde;
import io.confluent.kafka.streams.serdes.avro.GenericAvroSerde;
import org.apache.kafka.common.config.SaslConfigs;
import org.apache.kafka.common.config.SslConfigs;
import org.apache.kafka.common.serialization.Serde;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.common.utils.Bytes;
import org.apache.kafka.streams.KafkaStreams;
import org.apache.kafka.streams.KeyValue;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.StreamsConfig;
import org.apache.kafka.streams.kstream.*;
import org.apache.kafka.streams.state.KeyValueStore;

import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.*;

public class GeoStreamApp {
    static final String GEO_EVENTDATA_TOPIC = "geo_eventdata";
    static final String GEO_EVENTDATA_REQUEST_TOPIC = "geo_eventdata_lookup";
    static final String GEO_EVENTDATA_RESPONSE_TOPIC = "geo_eventdata_response";
    static final String GEO_EVENTDATA_STORE_TOPIC = "geo_eventdata_store";
    static final String GEO_EVENTDATA_PENDING_STORE_TOPIC = "geo_eventdata_pending_store";
    static final String GEO_EVENTDATA_ENRICHED_TOPIC = "geo_eventdata_enriched";
    static Schema enrichSchema =null;
    static Properties extProps = new Properties();

    public static void main(String[] args) {
        try {
            extProps = loadExternalConfig("./scripts/client.config");
        } catch (IOException e1) {
            // TODO Auto-generated catch block
            e1.printStackTrace();
        }

        Properties props = new Properties();
        props.putAll( extProps);
// The repartitioning topic will be named "${applicationId}-<name>-repartition",
// where "applicationId" is user-specified in StreamsConfig via parameter APPLICATION_ID_CONFIG,
// "<name>" is an internally generated name, and
// "-repartition" is a fixed suffix.

        props.put(StreamsConfig.APPLICATION_ID_CONFIG,"geo-streams-app");
        props.put(StreamsConfig.CLIENT_ID_CONFIG,"geo-stream-app-client");
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG,"earliest");
        props.put(AbstractKafkaAvroSerDeConfig.BASIC_AUTH_CREDENTIALS_SOURCE,"USER_INFO");
        props.put(AbstractKafkaAvroSerDeConfig.AUTO_REGISTER_SCHEMAS, true);
        props.put(StreamsConfig.DEFAULT_KEY_SERDE_CLASS_CONFIG, Serdes.String().getClass());
        props.put(StreamsConfig.DEFAULT_VALUE_SERDE_CLASS_CONFIG, GenericAvroSerde.class);
        props.put(CommonClientConfigs.SECURITY_PROTOCOL_CONFIG,"SASL_SSL"); // security.protocol
        props.put(SaslConfigs.SASL_MECHANISM, "PLAIN");
        props.put(SslConfigs.SSL_ENDPOINT_IDENTIFICATION_ALGORITHM_CONFIG, "https");
// required for change-log topics
        props.put(StreamsConfig.REPLICATION_FACTOR_CONFIG, 3);

        StreamsBuilder sb = new StreamsBuilder();

// configure the SerDe
        Map< String, String > srMap = new HashMap<>();
        srMap.put( "schema.registry.url", extProps.getProperty( "schema.registry.url" ) );
        srMap.put( "basic.auth.credentials.source","USER_INFO");
        srMap.put( "basic.auth.user.info",extProps.getProperty("schema.registry.basic.auth.user.info") );
        final Map<String, String> serdeConfig = srMap;
        final Serde<GenericRecord> valueGenericAvroSerde = new GenericAvroSerde();
// When you want to override serdes explicitly/selectively
        valueGenericAvroSerde.configure(serdeConfig, false); // `false` for record values

        final Serde<EventEnriched> eeAvroSerde = new SpecificAvroSerde<>();
        eeAvroSerde.configure( serdeConfig, false);
///////////////////////
// stream of raw events
///////////////////////
        KStream<String, GenericRecord> geoStream = sb.stream(GEO_EVENTDATA_TOPIC);

// introduce artificial key
//        Random r = new Random();
//        KStream<String, GenericRecord> geoKeyedStream = geoStream.map(
//                (key, value) -> KeyValue.pair( String.valueOf(r.nextInt(10)), value));

// use address as key
// todo: all lower case, trim and remove duplicate white space
        KStream<String, GenericRecord> geoKeyedStream = geoStream.map(
                (key, value) -> KeyValue.pair( value.get("address").toString(), value));


///////////////////////////////////
// stream of lookup response events
///////////////////////////////////
        KStream<String, GenericRecord> msResponseStream = sb.stream(GEO_EVENTDATA_RESPONSE_TOPIC);

/////////////////////////////////////////////////////////////
// global KTable with lookup response info (city -> lat, lng)
/////////////////////////////////////////////////////////////
// Note, that this topic name is not the changelog topic;
// Instead, the table will be constructed from this topic and it is expected that this topic is maintained by someone else
// todo: replace with a regular table (like for pending events)
        GlobalKTable<String, GenericRecord> geoDataGT = sb.globalTable(GEO_EVENTDATA_STORE_TOPIC,
        Materialized.<String, GenericRecord, KeyValueStore<Bytes, byte[]>>as(
                "geodata-global-store" /* table/store name */)
                .withKeySerde(Serdes.String()) /* key serde */
                .withValueSerde( valueGenericAvroSerde ) /* value serde */
        );



////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Stream that only holds successful matches (join)   (left / stream / Event; right / table / EventEnriched)
////////////////////////////////////////////////////////////////////////////////////////////////////////////
        KStream<String, EventEnriched> geoEnrichedStream =
                geoKeyedStream.join(geoDataGT,
                        (key, value) -> key, 
                        ( leftValue, rightValue ) -> ( new EventEnriched( leftValue.get("address").toString(), leftValue.get("eventtype").toString(),
                                Double.valueOf(rightValue.get("lat").toString()),Double.valueOf( rightValue.get("lng").toString()))  )
                );
        geoEnrichedStream.print(Printed.toSysOut());
// publish successful matches downstream
        geoEnrichedStream.to(GEO_EVENTDATA_ENRICHED_TOPIC);

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Stream that holds matches or missing matches (leftJoin) (left / stream / Event; right / table, EventEnriched)
////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        KStream<String, EventEnriched> geoMaybeEnrichedStream =
                geoKeyedStream.leftJoin(geoDataGT,
                        (key, value) -> key, 
                        ( leftValue, rightValue ) -> ( new EventEnriched( leftValue.get("address").toString(), leftValue.get("eventtype").toString(),
                                rightValue == null ? null : Double.valueOf(rightValue.get("lat").toString()),rightValue == null ? null : Double.valueOf( rightValue.get("lng").toString()))  )
                );
        geoMaybeEnrichedStream.print(Printed.toSysOut());

///////////////////////////////////////////////////
//  Stream that holds events that failed enrichment
///////////////////////////////////////////////////
        KStream<String, EventEnriched> missingLatLngStream = geoMaybeEnrichedStream.filter( (k,v ) -> v.get("lat") == null );
        missingLatLngStream.print(Printed.toSysOut());

// request has a different schema
        KStream<String, EventRequest> mappedMissingLatLngStream = missingLatLngStream.map(
                (k,v) -> KeyValue.pair( k, new EventRequest( v.getAddress() ))
        );
        mappedMissingLatLngStream.print(Printed.toSysOut());

// pend no-match events
// Note: This requires a key for a compacted topic
// Note: This is a different schema, as we need to pend the eventtype as well
// through() avoids an additional repartitioning topic
// However, adding through now lead to another StreamsException in the below toTable()
// This was solved with an additional Produced... argument with the right SerDes
        KStream<String, EventEnriched> pendingStream = missingLatLngStream.map(
                (k,v) -> KeyValue.pair( k, new EventEnriched( v.getAddress(), v.getEventtype(), null, null ) )
        ).through(GEO_EVENTDATA_PENDING_STORE_TOPIC, Produced.with( Serdes.String(), eeAvroSerde ) );

        pendingStream.print(Printed.toSysOut());

//////////////////////////////////
// table that holds pending events
//////////////////////////////////
        KTable<String, EventEnriched> pendingGT2;
// the following line resulted in org.apache.kafka.streams.errors.StreamsException
//        pendingGT2 = pendingStream.toTable(Materialized.as("geo-pending-store"));

// new with 55; directly materialize
// previous map() results in a repartition topic (although not necessary)
        pendingGT2 = pendingStream.toTable( Materialized.<String, EventEnriched, KeyValueStore<Bytes, byte[]>>as(
                "geo-pending-store" /* table/store name */)
                .withKeySerde(Serdes.String()) /* key serde */
                .withValueSerde( eeAvroSerde ) /* value serde */ );


// todo: instead of writing to a topic, reduce to the table (new 5.5 toTable); this will eliminate the race condition
// in the previous design, the event was published to the given topic and async read into a prior table definition resulting in potential race conditions
// -> done
// todo: remove pending events, that have been enriched
// todo: punctuator to age the cache


// route no-match events to lookup service
// Note that we do this after we materialize the local state store for pending requests
        mappedMissingLatLngStream.to(GEO_EVENTDATA_REQUEST_TOPIC);


///////////////////////////////////////////////////////////////////////////////////////////////////////////
// Stream that holds enriched pending requests (left / stream / EventResponse; right / table, EventEnriched
///////////////////////////////////////////////////////////////////////////////////////////////////////////
        KStream<String, EventEnriched> resolvedPendingStream =
                msResponseStream.join( pendingGT2,
                        ( resp, tab ) -> new EventEnriched( resp.get("address").toString(), tab.getEventtype(),
                                Double.valueOf(resp.get("lat").toString()), Double.valueOf(resp.get("lng").toString())) );
        resolvedPendingStream.print(Printed.toSysOut());

// update event store
// Note, this needs to be changed similar to the pending store
        resolvedPendingStream.to(GEO_EVENTDATA_STORE_TOPIC);


// Note that this is a simplification
// Technically the output stream does not have to have the identical schema of the store
        resolvedPendingStream.to(GEO_EVENTDATA_ENRICHED_TOPIC);


        System.err.println( sb.build().describe() );
        KafkaStreams ks = new KafkaStreams( sb.build(), props );
        // start the streaming app
        ks.start();
        System.out.println("topology:" + ks.toString());

        // close application gracefully (incl. lambda function)
        Runtime.getRuntime().addShutdownHook( new Thread (ks::close));


    }

    public static Properties loadExternalConfig(String configFile) throws IOException {
        if (!Files.exists(Paths.get(configFile))) {
            throw new IOException(configFile + " not found.");
        }
        final Properties cfg = new Properties();
        try (InputStream inputStream = new FileInputStream(configFile)) {
            cfg.load(inputStream);
        }
        return cfg;
    }

}
