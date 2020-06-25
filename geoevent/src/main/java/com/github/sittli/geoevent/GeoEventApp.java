package com.github.sittli.geoevent;

//import com.github.sittli.geodata.Event;
import com.google.maps.GeoApiContext;
import com.google.maps.GeocodingApi;
import com.google.maps.errors.ApiException;
import com.google.maps.model.GeocodingResult;
import com.google.maps.model.LatLng;
import io.confluent.kafka.serializers.AbstractKafkaAvroSerDeConfig;
import org.apache.avro.Schema;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericRecord;
import org.apache.kafka.clients.CommonClientConfigs;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.*;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.config.SaslConfigs;
import org.apache.kafka.common.config.SslConfigs;
import org.apache.kafka.common.errors.SerializationException;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Duration;
import java.util.Collections;
import java.util.Properties;
import java.util.concurrent.Future;
import java.util.regex.Matcher;
import java.util.regex.Pattern;


public class GeoEventApp {

    static KafkaConsumer<String, Object> kc = null;
    static KafkaProducer<String, GenericRecord> kp = null;
    static Schema outSchema=null;
    static String INBOUND_TOPIC = "geo_eventdata_lookup";
    static String OUTBOUND_TOPIC = "geo_eventdata_response";
    static Logger logger = LoggerFactory.getLogger( GeoEventApp.class.getName() );
    static Properties extProps = new Properties();
    static String GOOGLE_MAPS_API_KEY = "<GOOGLE_MAPS_API_KEY>";

    private GeoEventApp() {
    }

    public static void main(String[] args) {

        GeoEventApp gea = new GeoEventApp();
        gea.run();
        Runtime.getRuntime().addShutdownHook( new Thread (kp::close));

    }
    public void run() {
        try {
            extProps = loadExternalConfig("<PATH_TO_GENERATED_CLIENT_CONFIG>/client.config");
        } catch (IOException e1) {
            // TODO Auto-generated catch block
            e1.printStackTrace();
        }

        kc = (KafkaConsumer<String, Object>) createConsumer();
        kp = (KafkaProducer<String, GenericRecord>) createProducer();
        this.consume();

    }

    /*
     * create a Consumer
     * */
    private static Consumer<String, Object> createConsumer() {
        Properties props = new Properties();
        props.putAll(extProps);
        props.put(ConsumerConfig.GROUP_ID_CONFIG,"geo-lookup-ms");
         props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, extProps.getProperty("bootstrap.servers"));

        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG,"earliest");
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, io.confluent.kafka.serializers.KafkaAvroDeserializer.class);

        props.put(AbstractKafkaAvroSerDeConfig.BASIC_AUTH_CREDENTIALS_SOURCE,"USER_INFO");
        props.put(AbstractKafkaAvroSerDeConfig.AUTO_REGISTER_SCHEMAS, false);
        props.put(CommonClientConfigs.SECURITY_PROTOCOL_CONFIG,"SASL_SSL"); // security.protocol
        props.put(SaslConfigs.SASL_MECHANISM, "PLAIN");
        props.put(SslConfigs.SSL_ENDPOINT_IDENTIFICATION_ALGORITHM_CONFIG, "https");
        return new KafkaConsumer<String, Object>(props);
    }

    /*
     * create a Producer
     * */
    private static Producer<String, GenericRecord> createProducer() {
        createProducerSchema();
        Properties props = new Properties();
        props.putAll( extProps );
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, io.confluent.kafka.serializers.KafkaAvroSerializer.class);
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        props.put(ProducerConfig.RETRIES_CONFIG, "0");
        props.put(ProducerConfig.BATCH_SIZE_CONFIG, "16384");
        props.put(ProducerConfig.LINGER_MS_CONFIG, "1"); // 1 milisecond
        props.put(ProducerConfig.BUFFER_MEMORY_CONFIG, "33554432");
        props.put(AbstractKafkaAvroSerDeConfig.BASIC_AUTH_CREDENTIALS_SOURCE,"USER_INFO");
        props.put(AbstractKafkaAvroSerDeConfig.AUTO_REGISTER_SCHEMAS, false);
        props.put(CommonClientConfigs.SECURITY_PROTOCOL_CONFIG,"SASL_SSL");
        props.put(SaslConfigs.SASL_MECHANISM, "PLAIN");
        props.put(SslConfigs.SSL_ENDPOINT_IDENTIFICATION_ALGORITHM_CONFIG, "https");
        return new KafkaProducer<String, GenericRecord>(props);
    }


    private static void createProducerSchema() {
// We must specify the Avro schemas for all intermediate (Avro) classes, if any.
        final InputStream geodata_response = GeoEventApp.class.getClassLoader()
                        .getResourceAsStream("avro/com.github.sittli.geoevent/geodata_event_response.avsc");
        try {
            outSchema = new Schema.Parser().parse(geodata_response);
        } catch (IOException e) {
            e.printStackTrace();
        }
    }


    public void consume() {
        kc.subscribe(Collections.singleton(INBOUND_TOPIC));
        final Pattern offsetPattern = Pattern.compile("\\w*offset*\\w[ ]\\d+");
        final Pattern partitionPattern = Pattern.compile("\\w*" + INBOUND_TOPIC + "*\\w[-]\\d+");
        while (true) {
            try {
                // deserialization already happens in poll()
                ConsumerRecords<String, Object> records = kc.poll(Duration.ofMillis(1000));
//                logger.info("#records: " + records.count() );
                records.forEach(this::processRecord);
            }
            catch ( SerializationException se ) {
                String text = se.getMessage();
                // how to seek next offset of current partition?
                // analyze exception with regex (https://jonboulineau.me/blog/kafka/dealing-with-bad-records-in-kafka)
                Matcher mPart = partitionPattern.matcher(text);
                Matcher mOff = offsetPattern.matcher(text);

                mPart.find();
                Integer partition = Integer.parseInt(mPart.group().replace(INBOUND_TOPIC + "-", ""));
                mOff.find();
                Long offset = Long.parseLong(mOff.group().replace("offset ", ""));
                logger.info(String.format(
                        "'Poison pill' found at partition {0}, offset {1} ... skipping", partition, offset));
                kc.seek(new TopicPartition(INBOUND_TOPIC, partition), offset + 1);

                se.printStackTrace();
            }
            catch (Exception e) {
                e.printStackTrace();
            }
        }
    }


    private void processRecord(ConsumerRecord<String, Object> record) {
        try {
            logger.info( "Class of Value: " +  record.value().getClass() );
            logger.info("Consumption - received new metadata \n" +
                    "Key: " + record.key() + "\n" +
                    "Value: " + record.value() + "\n" +
                    "Partition: " + record.partition() + "\n" +
                    "Offset: " + record.offset() + "\n" +
                    "Headers: " + record.headers() + "\n" +
                    "Timestamp: " + record.timestamp() + "\n");
            GenericRecord gr = (GenericRecord) record.value();
            logger.info( "address = " + gr.get("address").toString() );
// retrieve lat / lng for address
//            LatLng ll = getGeoLatLng_Simulator( gr.get("address").toString() );
            LatLng ll = getGeoLatLng( gr.get("address").toString() );

// create enriched record
            GenericRecord nGr = new GenericData.Record(outSchema);
            nGr.put( "address", gr.get("address") );
            nGr.put( "lat", ll.lat );
            nGr.put( "lng", ll.lng );
            ProducerRecord<String, GenericRecord> newRecord =
                    new ProducerRecord<String, GenericRecord>(OUTBOUND_TOPIC, record.key(), nGr );
            logger.info("pre send()");
// publish enriched record
            Future future = kp.send( newRecord );
            logger.info("post send()");
//            future.get();
            logger.info("post future.get()");
// flush every record (just for demo purpose)
            kp.flush();

        } catch (Exception e) {
            logger.error("caught exception " );
            e.printStackTrace();
            // handle error
        }
    }

    private LatLng getGeoLatLng( String address ) {
        GeoApiContext context = new GeoApiContext.Builder()
                .apiKey(GOOGLE_MAPS_API_KEY)
                .build();
        GeocodingResult[] results = new GeocodingResult[0];
        try {
            results = GeocodingApi.geocode(context, address+",Germany").await();
        } catch (ApiException e) {
            e.printStackTrace();
        } catch (InterruptedException e) {
            e.printStackTrace();
        } catch (IOException e) {
            e.printStackTrace();
        }
        LatLng location = results[0].geometry.location;
        logger.info("lat: " + location.lat  + " | lng: " + location.lng );
        return location;
    }

    private LatLng getGeoLatLng_Simulator( String address ) {
      return new LatLng( 48.1351253, 11.5819805);
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
