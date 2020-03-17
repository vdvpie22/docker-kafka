#!/bin/sh

TAG=$EIP_TAG

MY_INST_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)

MY_IP="UNDEFINED"

ZOOKEEPER_NODES=""
ZOOKEEPER_CONNECT=""
COUNTER=1
ASSIGNED=0

eips=$(aws ec2 describe-addresses --region eu-central-1 --filter Name=tag-value,Values=$TAG)
for eip in $(echo "${eips}" | jq -rc '.Addresses[]'); do
    INST_ID=$(echo $eip | jq -r '.InstanceId')
    ALLOC=$(echo $eip | jq -r '.AllocationId')
    IP=$(echo $eip | jq -r '.PublicIp')
    IP_INT=$(echo $IP | tr . '\n' | awk '{s = s*256 + $1} END{print s}')
    if [[ $INST_ID == 'null' ]] && [[ $ASSIGNED == 0 ]]; then
        ASSIGNATION_FAILED=0
        aws ec2 associate-address --region eu-central-1 --allocation-id $ALLOC --instance-id $MY_INST_ID || ASSIGNATION_FAILED=1
        if [[ $ASSIGNATION_FAILED == 0 ]]; then
            ASSIGNED=1
            MY_IP=$IP
            IP='0.0.0.0'
            echo "Assigned $IP"
        fi
    fi
    
    ZOOKEEPER_NODES=$ZOOKEEPER_NODES"server.$IP_INT=$IP:2888:3888"$'\n'
    if [ $COUNTER == 1 ]; then
        ZOOKEEPER_CONNECT="$IP:2181"
    else
        ZOOKEEPER_CONNECT="$ZOOKEEPER_CONNECT,$IP:2181"
    fi
    COUNTER=$(($COUNTER+1))
done

MY_ZOOKEEPER_ID=$(echo $MY_IP | tr . '\n' | awk '{s = s*256 + $1} END{print s}') 

ADVERTISED_HOST = $MY_IP


# Optional ENV variables:
# * ADVERTISED_HOST: the external ip for the container, e.g. `docker-machine ip \`docker-machine active\``
# * ADVERTISED_PORT: the external port for Kafka, e.g. 9092
# * ZK_CHROOT: the zookeeper chroot that's used by Kafka (without / prefix), e.g. "kafka"
# * LOG_RETENTION_HOURS: the minimum age of a log file in hours to be eligible for deletion (default is 168, for 1 week)
# * LOG_RETENTION_BYTES: configure the size at which segments are pruned from the log, (default is 1073741824, for 1GB)
# * NUM_PARTITIONS: configure the default number of log partitions per topic

# Configure advertised host/port if we run in helios
if [ ! -z "$HELIOS_PORT_kafka" ]; then
    ADVERTISED_HOST=`echo $HELIOS_PORT_kafka | cut -d':' -f 1 | xargs -n 1 dig +short | tail -n 1`
    ADVERTISED_PORT=`echo $HELIOS_PORT_kafka | cut -d':' -f 2`
fi

# Set the external host and port
if [ ! -z "$ADVERTISED_HOST" ]; then
    echo "advertised host: $ADVERTISED_HOST"
    if grep -q "^advertised.host.name" $KAFKA_HOME/config/server.properties; then
        sed -r -i "s/#(advertised.host.name)=(.*)/\1=$ADVERTISED_HOST/g" $KAFKA_HOME/config/server.properties
    else
        echo "\n advertised.host.name=$ADVERTISED_HOST" >> $KAFKA_HOME/config/server.properties
    fi
fi
if [ ! -z "$ADVERTISED_PORT" ]; then
    echo "advertised port: $ADVERTISED_PORT"
    if grep -q "^advertised.port" $KAFKA_HOME/config/server.properties; then
        sed -r -i "s/#(advertised.port)=(.*)/\1=$ADVERTISED_PORT/g" $KAFKA_HOME/config/server.properties
    else
        echo "\n advertised.port=$ADVERTISED_PORT" >> $KAFKA_HOME/config/server.properties
    fi
fi

# Set the zookeeper chroot
if [ ! -z "$ZK_CHROOT" ]; then
    # wait for zookeeper to start up
    until /usr/share/zookeeper/bin/zkServer.sh status; do
      sleep 0.1
    done

    # create the chroot node
    echo "create /$ZK_CHROOT \"\"" | /usr/share/zookeeper/bin/zkCli.sh || {
        echo "can't create chroot in zookeeper, exit"
        exit 1
    }

    # configure kafka
    sed -r -i "s/(zookeeper.connect)=(.*)/\1=localhost:2181\/$ZK_CHROOT/g" $KAFKA_HOME/config/server.properties
fi

# Allow specification of log retention policies
if [ ! -z "$LOG_RETENTION_HOURS" ]; then
    echo "log retention hours: $LOG_RETENTION_HOURS"
    sed -r -i "s/(log.retention.hours)=(.*)/\1=$LOG_RETENTION_HOURS/g" $KAFKA_HOME/config/server.properties
fi
if [ ! -z "$LOG_RETENTION_BYTES" ]; then
    echo "log retention bytes: $LOG_RETENTION_BYTES"
    sed -r -i "s/#(log.retention.bytes)=(.*)/\1=$LOG_RETENTION_BYTES/g" $KAFKA_HOME/config/server.properties
fi

# Configure the default number of log partitions per topic
if [ ! -z "$NUM_PARTITIONS" ]; then
    echo "default number of partition: $NUM_PARTITIONS"
    sed -r -i "s/(num.partitions)=(.*)/\1=$NUM_PARTITIONS/g" $KAFKA_HOME/config/server.properties
fi

# Enable/disable auto creation of topics
if [ ! -z "$AUTO_CREATE_TOPICS" ]; then
    echo "auto.create.topics.enable: $AUTO_CREATE_TOPICS"
    echo "auto.create.topics.enable=$AUTO_CREATE_TOPICS" >> $KAFKA_HOME/config/server.properties
fi

# Run Kafka
$KAFKA_HOME/bin/kafka-server-start.sh $KAFKA_HOME/config/server.properties
