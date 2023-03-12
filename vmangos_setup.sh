#!/bin/bash
HOME=`pwd`

# Script introduction and setup instructions
# ASCII Art by: http://www.patorjk.com/software/taag/
echo "###########################################################################################"
echo "This script will install Classic World of Warcraft by VMaNGOS."
echo "###########################################################################################"
echo " "
echo "1. The World, Auth, and Database server will all be installed locally on this machine"
echo "2. This script must be run as root (sudo) for it to work properly. (sudo bash script.sh)"
echo "3. This script has been tested on Ubuntu 22.04 LTS - Server."
echo "
   ___ _               _      
  / __\ | __ _ ___ ___(_) ___ 
 / /  | |/ _` / __/ __| |/ __|
/ /___| | (_| \__ \__ \ | (__ 
\____/|_|\__,_|___/___/_|\___|
                              
 __    __     __    __        
/ / /\ \ \___/ / /\ \ \       
\ \/  \/ / _ \ \/  \/ /       
 \  /\  / (_) \  /\  /        
  \/  \/ \___/ \/  \/         
                          
read -p "Press any key to continue"


# Set the number of processor cores
CPU=$(grep -c ^processor /proc/cpuinfo)

read -p "Pleaset upload a copy of the 1.12 client /Data folder now. Enter the path: CLIENTDATA=${CLIENTDATA:-/home/$USER/Data}

read -p "Where would you like VMaNGOS to be installed to? [/opt/mangos]: " INSTALLROOT
INSTALLROOT=${INSTALLROOT:-/opt/mangos}

read -p "Set a user name for the database server admin account: [$USER]: " SQLADMINUSER
SQLADMINUSER=${SQLADMINUSER:-$USER}

read -p "Choose an IP range to restrict the SQL Admin user to log in from: (Use % as a wildcard): [%]: " SQLADMINIP
SQLADMINIP=${SQLADMINIP:-%}

read -p "Choose a password for the database admin user, ${SQLADMINUSER} : " SQLADMINPASS

read -p "Choose a name for the World Database [world]:" WORLDDB
WORLDDB=${WORLDDB:-world}

read -p "Choose a name for the Auth Database: [auth]: " AUTHDB
AUTHDB=${AUTHDB:-auth}

read -p "Choose a name for the Characters Database [characters]:" CHARACTERDB
CHARACTERDB=${CHARACTERDB:-characters}

read -p "Choose a database user account that will be used by the VMaNGOS server [mangos]: " MANGOSDBUSER
MANGOSDBUSER=${MANGOSDBUSER:-mangos}

read -p "Choose a password for the ${MANGOSDBUSER} database user account: " MANGOSDBPASS

read -p "Choose a Linux OS user account to run the MaNGOS server processes [mangos]: " MANGOSOSUSER
MANGOSOSUSER=${MANGOSOSUSER:-mangos}

# Detect the Server's IP Address and pause the install for a moment.

SERVERIP=`ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'`
echo " "
echo " "
echo "=============================================== NOTE ================================================"
echo "I detected this machine's IP address as: ${SERVERIP}."
echo " "
echo "Resuming in installation in 3 seconds..."
sleep 3

# Create the VMaNGOS directory(s)
mkdir $INSTALLROOT
mkdir $INSTALLROOT/run
mkdir $INSTALLROOT/run/5875
mkdir $INSTALLROOT/build
mkdir $INSTALLROOT/logs 
mkdir $INSTALLROOT/logs/mangosd
mkdir $INSTALLROOT/logs/realmd
mkdir $INSTALLROOT/logs/honor
cd $INSTALLROOT

echo "######################################################################################################"
echo "Installing the required software needed to compile and run VMaNGOS."
echo "######################################################################################################"

#Install Base Software Requirements
sudo apt net-tools install libace-dev libtbb-dev openssl libssl-dev libmysqlclient-dev p7zip-full ntp ntpdate checkinstall build-essential gcc g++ automake git-core autoconf make patch libmysql++-dev mariadb-server libtool grep binutils zlib1g-dev libbz2-dev cmake libboost-all-dev unzip -y
export ACE_ROOT=/usr/include/ace
export TBB_ROOT_DIR=/usr/include/tbb

#Create a new user to run the VMaNGOS server
useradd -m -d /home/$MANGOSOSUSER -c "VMaNGOS" -s /bin/bash -U $MANGOSOSUSER

# Move the client Data directory to the install path
mv $CLIENTDIR $INSTALLROOT/

# Allow the MariaDB Server to accept remote connections.
sed -i "s/127.0.0.1/$SERVERIP/" /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mysql.service

# Clone in the VMaNGOS git repos
git clone -b development https://github.com/vmangos/core source
git clone https://github.com/brotalnia/database db

# Compile the VMaNGOS source code
cd $INSTALLROOT/build
cmake $INSTALLROOT/source -DUSE_EXTRACTORS=1 -DCMAKE_INSTALL_PREFIX=$INSTALLROOT/run
make -j $CPU && make install

# Rename the Config files.
cp $INSTALLROOT/run/etc/mangosd.conf.dist $INSTALLROOT/run/etc/mangosd.conf
cp $INSTALLROOT/run/etc/realmd.conf.dist $INSTALLROOT/run/etc/realmd.conf

echo " "
echo "######################################################################################################"
echo "Extracting the client data"
echo "######################################################################################################"

# Copy the extractor tools to where they are needed.
cp $INSTALLROOT/run/bin/mapextractor $INSTALLROOT
cp $INSTALLROOT/run/bin/vmap_assembler $INSTALLROOT
cp $INSTALLROOT/run/bin/vmapextractor
 $INSTALLROOT
cp $INSTALLROOT/run/bin/MoveMapGen $INSTALLROOT
cp $INSTALLROOT/source/contrib/mmap/offmesh.txt $INSTALLROOT

# Run the extraction process
cd $INSTALLROOT
./mapextractor
./vmapextractor
./vmap_assembler
./MoveMapGen

# Move the extracted content to where the server can read them
mv $INSTALLROOT/dbc $INSTALLROOT/run/bin/5875
mv $INSTALLROOT/maps $INSTALLROOT/run/bin/
mv $INSTALLROOT/mmaps $INSTALLROOT/run/bin/
mv $INSTALLROOT/vmaps $INSTALLROOT/run/bin/

# Cleanup unused asset directories
rm -rf $INSTALLROOT/Buildings
rm -rf $INSTALLROOT/Cameras

echo " "
echo "######################################################################################################"
echo "Starting the Database setup"
echo "######################################################################################################"

# Create the SQL script that creates the databases & db users
cat <<EOF > $INSTALLROOT/db-setup.sql
CREATE DATABASE \`$AUTHDB\`;
CREATE DATABASE \`$WORLDDB\`;
CREATE DATABASE \`$CHARACTERDB\`;
CREATE DATABASE \`logs\`;
CREATE USER '$MANGOSDBUSER'@'$SERVERIP' IDENTIFIED BY '$MANGOSDBPASS';
CREATE USER '$SQLADMINUSER'@'$SQLADMINIP' IDENTIFIED BY '$SQLADMINPASS';
GRANT USAGE ON *.* TO '$MANGOSDBUSER'@'$SERVERIP';
GRANT ALL PRIVILEGES ON *.* TO '$SQLADMINUSER'@'$SQLADMINIP' WITH GRANT OPTION;
GRANT ALL PRIVILEGES  ON \`$AUTHDB\`.* TO '$MANGOSDBUSER'@'$SERVERIP';
GRANT ALL PRIVILEGES  ON \`$WORLDDB\`.* TO '$MANGOSDBUSER'@'$SERVERIP';
GRANT ALL PRIVILEGES  ON \`$CHARACTERDB\`.* TO '$MANGOSDBUSER'@'$SERVERIP';
GRANT ALL PRIVILEGES  ON \`logs\`.* TO '$MANGOSDBUSER'@'$SERVERIP';
FLUSH PRIVILEGES;
EOF

#Run the db setup SQL script to create the new databases and user accounts.
mysql < $INSTALLROOT/db-setup.sql

# Clean-up the SQL script so we don't expose any passwords.
rm $INSTALLROOT/db-setup.sql

# Download and extract the latest full world DB
cd $INSTALLROOT/db
wget https://github.com/brotalnia/database/blob/master/world_full_14_june_2021.7z?raw=true
mv world_full_14_june_2021.7z?raw=true world_full_14_june_2021.7z
7z x world_full_14_june_2021.7z

# Install the contents of the full DB we just downloaded & then tidy up.
mysql $WORLDDB < world_full_14_june_2021.sql
rm $INSTALLROOT/db/*.7z

# Populate the Characters, Auth, and Logs databases from the source directory
mysql $CHARACTERDB < $INSTALLROOT/source/sql/characters.sql
mysql logs < $INSTALLROOT/source/sql/logs.sql
mysql $AUTHDB < $INSTALLROOT/source/sql/logon.sql

# Run migrations against the WorldDB
cd $INSTALLROOT/source/sql/migrations
./merge.sh
mysql $WORLDDB < world_db_updates.sql
mysql logs < logs_db_updates.sql
mysql $CHARACTERDB < characters_db_updates.sql
mysql $AUTHDB < logon_db_updates.sql

echo "######################################################################################################"
echo "Updating the VMaNGOS config files so the World and Auth servers can access the database(s) "
echo "######################################################################################################"

# Update the Auth server and World server configuration file.
sed -i "s/127.0.0.1;3306;mangos;mangos;realmd/$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB/g" $INSTALLROOT/run/etc/realmd.conf
sed -i "s/BindIP = \"0.0.0.0\"/BindIP = \"$SERVERIP\"/g" $INSTALLROOT/run/etc/realmd.conf

sed -i "s/127.0.0.1;3306;mangos;mangos;mangos_auth/$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB/g" $INSTALLROOT/run/etc/mangosd.conf
sed -i "s/127.0.0.1;3306;mangos;mangos;mangos_world/$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$WORLDDB/g" $INSTALLROOT/run/etc/mangosd.conf
sed -i "s/127.0.0.1;3306;mangos;mangos;mangos_characters/$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$CHARACTERDB/g" $INSTALLROOT/run/etc/mangosd.conf

# Update the log & honor directory setting in the World Server config file.
sed -i "s/LogsDir = \"\"/LogsDir =\"$INSTALLROOT/logs\"" $INSTALLROOT/run/etc/mangosd.conf
sed -i "s/HonorDir = \"\"/HonorDir =\"$INSTALLROOT/logs/honor\"" $INSTALLROOT/run/etc/mangosd.conf


echo "######################################################################################################"
echo "Updating the 'realmlist' table in the Realm DB so VMaNGOS knows what IP address to give clients."
echo "######################################################################################################"

# Create the realm setup SQL script with placeholder value for the Realm IP
cat <<EOF > $INSTALLROOT/realmsetup.sql
UPDATE \`auth\`.\`realmlist\` SET \`address\` = 'SERVERIP', \`localaddress\` = 'SERVERIP' WHERE (\`id\` = '1');
EOF

# Update the placeholder value for the realm IP with the detected server IP
sed -i "s/SERVERIP/$SERVERIP/g" $INSTALLROOT/realmsetup.sql

#Run the modified SQL command to update the realmlist table in the realm database.
mysql $REALMDB < $INSTALLROOT/realmsetup.sql
rm $INSTALLROOT/realmsetup.sql

#Clean up the file system permissions
chown $MANGOSOSUSER:$MANGOSOSUSER $INSTALLROOT -R


echo "######################################################################################################"
echo "Creating & starting the system services to run the World and Realm server services."
echo "######################################################################################################"
cd $HOME

#Create the Auth service definition.
cat <<EOF > /etc/systemd/system/auth.service
[Unit]
Description=Classic WoW Server.  Powered by: VMaNGOS.
After=network.target mysql.service

[Service]
Type=simple
User=${MANGOSOSUSER}
ExecStart=${INSTALLROOT}/run/bin/realmd
WorkingDirectory=${INSTALLROOT}/run/bin/
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF

#Create the World service definition
cat <<EOF > /etc/systemd/system/world.service
[Unit]
Description=Classic WoW Server.  Powered by: VMaNGOS.
After=network.target mysql.service

[Service]
Type=simple
User=${MANGOSOSUSER}
StandardInput=tty
TTYPath=/dev/tty3
TTYReset=yes
TTYVHangup=yes
ExecStart=${INSTALLROOT}/run/bin/mangosd
WorkingDirectory=${INSTALLROOT}/run/bin/
PIDFile=${INSTALLROOT}/run/bin/worldserver.pid
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF

# Secure the MariaDB installation
/usr/bin/mysql_secure_installation

# Enable && start the new services
systemctl enable auth
systemctl enable world

systemctl start auth
systemctl start world

echo " "
echo " "
echo " "
echo " "

echo "######################################################################################################"
echo "Congrats!  The installation has been completed.  You should now be able to connect to the SQL server"
echo "using your admin account remotly using a SQL Client like MySQL Workbench with the ${SQLADMINUSER}"
echo "database credentials you setup earlier.  "
echo " "
echo "Please update your WoW Game clients realmlist.wtf to the following:  set realmlist ${SERVERIP}"
echo "######################################################################################################"
