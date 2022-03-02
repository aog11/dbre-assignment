#!/bin/bash

#Safety check to avoid running the script again
if [ -d /usr/pgsql-13/bin/ ]
then
    echo "PostgreSQL 13 binaries are present, exiting script."
    exit 1
fi

#Variable declaration
VM1=pgsql-vm1
VM2=pgsql-vm2
PRIVATE_IP1=10.1.0.2
PRIVATE_IP2=10.1.0.3
BUCKET_URL=gs://postgres_backup_bucket11251
PGBASE=/var/lib/pgsql/13
PGDATA=/var/lib/pgsql/13/data

#Partitioning the attached disk and mounting it to the postgres installation default path
echo 'type=83' | sudo sfdisk /dev/sdb
sudo mkfs.xfs /dev/sdb1
sudo mkdir -p /var/lib/pgsql/13/
sudo mount -t xfs /dev/sdb1 /var/lib/pgsql/13/

#PostgreSQL 13 installation
#Courtesy of https://www.postgresql.org/download/linux/redhat/
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql13-server
sudo /usr/pgsql-13/bin/postgresql-13-setup initdb

#Adding entries to /etc/host with the private IP of the machines
cat << EOF | sudo tee -a /etc/hosts
$PRIVATE_IP1 $VM1
$PRIVATE_IP2 $VM2
EOF

#Adding entries to pg_hba for the user that will handle replication and md5 for the rest of users
cat << EOF | sudo tee -a $PGDATA/pg_hba.conf
host    all             replicator      $VM1                    trust
host    replication     replicator      $VM1                    trust
host    all             replicator      $VM2                    trust
host    replication     replicator      $VM2                    trust
host    all             all             0.0.0.0/0               md5
EOF

#Starting postgresql-13 service in Master node and initializing pgbench schema
if [ $(hostname) == $VM1 ]
then
    
    #Allowing connections from any address and setting replication slots in Master
    cat << EOF | sudo tee -a $PGDATA/postgresql.conf
listen_addresses = '*'
max_wal_senders = 10
max_replication_slots = 10
log_filename = 'postgresql-%Y-%m-%d.log'
EOF

    #Script to create the replication user, replication slots and pgbench database
    cat > /tmp/dbscript.sql << EOF
CREATE USER replicator WITH replication;
SELECT * FROM pg_create_physical_replication_slot('node_1_slot');
SELECT * FROM pg_create_physical_replication_slot('node_2_slot');
CREATE DATABASE pgbench;
EOF

    #Starting postgresql-13 service
    sudo systemctl start postgresql-13

    #Running dbscript.sql
    sudo su - postgres -c "psql -d postgres < /tmp/dbscript.sql"

    #Initializing pgbench schema
    sudo su - postgres -c "/usr/pgsql-13/bin/pgbench -i -d pgbench"
fi

#Adjusting replication settings in standby server and using pg_basebackup to replicate Master
if [ $(hostname) == $VM2 ]
then
    
    #Replication settings in standby server
    cat << EOF | sudo tee -a $PGDATA/postgresql.conf
listen_addresses = '*'
wal_level = replica
wal_log_hints = on
archive_mode = off
archive_command = ''
restore_command = ''
recovery_target_timeline = 'latest'
max_wal_senders = 10
max_replication_slots = 10
primary_slot_name = 'node_1_slot'
hot_standby = on
log_filename = 'postgresql-%Y-%m-%d.log'
EOF

    #Backing up conf files
    sudo cp $PGDATA/pg_hba.conf $PGDATA/postgresql.conf $PGDATA/postgresql.auto.conf $PGBASE

    #Deleting $PGDATA directory (needed for pg_basebackup)
    sudo rm -rf $PGDATA

    #Coping data directory from master
    sudo su - postgres -c "pg_basebackup -h $VM1 -U replicator -p 5432 -D $PGDATA -Fp -Xs -P -R --checkpoint=fast"

    #Restoring standby config files
    sudo cp $PGBASE/pg_hba.conf $PGBASE/postgresql.conf $PGDATA/

    #Starting postgresql-13 service in standby
    sudo systemctl start postgresql-13

    #Creating the database backup script
    cat << EOF | tee /var/lib/pgsql/db_backup.sh
pg_dumpall -U postgres -f /var/lib/pgsql/13/backups/db_backup_\$(date +%Y%m%d).sql
gsutil cp /var/lib/pgsql/13/backups/db_backup_\$(date +%Y%m%d).sql $BUCKET_URL
EOF

    sudo chmod +x /var/lib/pgsql/13/db_backup.sh

    #Adding the script to postgres crontab
    sudo su - postgres -c "echo \"0 1 * * * /var/lib/pgsql/db_backup.sh\" | crontab -"

    #Authenticating service account with postgres user
    sudo su - postgres -c "gcloud auth activate-service-account --key-file=/tmp/account.json"

fi
