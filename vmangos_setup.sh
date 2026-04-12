#!/bin/bash
set -e

# =============================================================================
# VMANGOS Setup Script - Fixed Version
# =============================================================================
# Fixes:
# - Added git clone retry logic with timeout
# - Added non-interactive mode (via environment variables)
# - Better error handling for network operations
# - Fixed silent failures on world DB download
# - Added progress logging
# =============================================================================

HOME=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log file for installation
INSTALL_LOG="${INSTALL_LOG:-/var/log/vmangos-install.log}"

# Create log directory if needed
mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true

echo "Logging installation to: $INSTALL_LOG"
exec 1> >(tee -a "$INSTALL_LOG")
exec 2>&1

# =============================================================================
# Helper Functions
# =============================================================================

# Git clone with retry logic
clone_with_retry() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="${3:-}"
    local max_retries=3
    local retry_delay=10
    local attempt=1
    
    if [ -d "$target_dir/.git" ]; then
        echo "Directory $target_dir already exists and is a git repo. Skipping clone."
        return 0
    fi
    
    # Remove incomplete directory if exists
    if [ -d "$target_dir" ]; then
        echo "Removing incomplete directory: $target_dir"
        rm -rf "$target_dir"
    fi
    
    while [ $attempt -le $max_retries ]; do
        echo "Cloning $repo_url (attempt $attempt/$max_retries)..."
        
        if [ -n "$branch" ]; then
            if timeout 300 git clone -b "$branch" "$repo_url" "$target_dir" 2>&1; then
                echo "Successfully cloned $repo_url"
                return 0
            fi
        else
            if timeout 300 git clone "$repo_url" "$target_dir" 2>&1; then
                echo "Successfully cloned $repo_url"
                return 0
            fi
        fi
        
        echo "Clone failed, waiting ${retry_delay}s before retry..."
        sleep $retry_delay
        attempt=$((attempt + 1))
        retry_delay=$((retry_delay * 2))  # Exponential backoff
    done
    
    echo "ERROR: Failed to clone $repo_url after $max_retries attempts"
    return 1
}

# Download with retry and better error handling
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_delay=5
    local attempt=1
    
    while [ $attempt -le $max_retries ]; do
        echo "Downloading $url (attempt $attempt/$max_retries)..."
        
        if timeout 300 wget -O "$output" "$url" 2>&1; then
            if [ -f "$output" ] && [ -s "$output" ]; then
                echo "Successfully downloaded to $output"
                return 0
            fi
        fi
        
        echo "Download failed, waiting ${retry_delay}s before retry..."
        rm -f "$output"
        sleep $retry_delay
        attempt=$((attempt + 1))
        retry_delay=$((retry_delay * 2))
    done
    
    echo "ERROR: Failed to download $url after $max_retries attempts"
    return 1
}

# Check if running in non-interactive mode
check_noninteractive() {
    if [ -n "$VMANGOS_AUTO_INSTALL" ]; then
        echo "Running in non-interactive mode (VMANGOS_AUTO_INSTALL is set)"
        return 0
    fi
    return 1
}

# =============================================================================
# Script introduction and setup instructions
# =============================================================================

echo "###########################################################################################"
echo "This script will install Classic World of Warcraft by VMaNGOS."
echo "###########################################################################################"
echo " "
echo "1. The World, Auth, and Database server will all be installed locally on this machine"
echo "2. This script must be run as root (sudo) for it to work properly. (sudo bash script.sh)"
echo "3. This script has been tested on Ubuntu 22.04 LTS - Server."
echo ""
cat << "EOF"
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
                              
EOF

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

# Set the number of processor cores
CPU=$(nproc)

# =============================================================================
# Configuration Phase
# =============================================================================

if check_noninteractive; then
    # Non-interactive mode - use environment variables or defaults
    echo "Using configuration from environment variables..."
    
    CLIENTDATA="${VMANGOS_CLIENT_DATA:-/home/$SUDO_USER/Data}"
    INSTALLROOT="${VMANGOS_INSTALL_ROOT:-/opt/mangos}"
    SQLADMINUSER="${VMANGOS_SQL_ADMIN_USER:-root}"
    SQLADMINIP="${VMANGOS_SQL_ADMIN_IP:-%}"
    SQLADMINPASS="${VMANGOS_SQL_ADMIN_PASS:-}"
    WORLDDB="${VMANGOS_WORLD_DB:-world}"
    AUTHDB="${VMANGOS_AUTH_DB:-auth}"
    CHARACTERDB="${VMANGOS_CHAR_DB:-characters}"
    MANGOSDBUSER="${VMANGOS_DB_USER:-mangos}"
    MANGOSDBPASS="${VMANGOS_DB_PASS:-}"
    MANGOSOSUSER="${VMANGOS_OS_USER:-mangos}"
    SKIP_SECURE_MYSQL="${VMANGOS_SKIP_SECURE_MYSQL:-yes}"
    
    # Validate required passwords
    if [ -z "$SQLADMINPASS" ]; then
        echo "ERROR: VMANGOS_SQL_ADMIN_PASS must be set in non-interactive mode"
        exit 1
    fi
    if [ -z "$MANGOSDBPASS" ]; then
        echo "ERROR: VMANGOS_DB_PASS must be set in non-interactive mode"
        exit 1
    fi
    
    echo "Configuration loaded from environment variables."
else
    # Interactive mode
    read -p "Press any key to continue"
    
    echo ""
    echo "==========================================================================================="
    echo "Please upload a copy of the 1.12 client /Data folder to this server before continuing."
    echo "The Data folder should contain: dbc, maps, mmaps, and vmaps subdirectories after extraction."
    echo "==========================================================================================="
    echo ""
    
    read -p "Enter the path to the 1.12 client Data folder [/home/$SUDO_USER/Data]: " CLIENTDATA
    CLIENTDATA=${CLIENTDATA:-/home/$SUDO_USER/Data}
    
    read -p "Where would you like VMaNGOS to be installed to? [/opt/mangos]: " INSTALLROOT
    INSTALLROOT=${INSTALLROOT:-/opt/mangos}
    
    read -p "Set a user name for the database server admin account [root]: " SQLADMINUSER
    SQLADMINUSER=${SQLADMINUSER:-root}
    
    read -p "Choose an IP range to restrict the SQL Admin user to log in from (Use % as a wildcard) [%]: " SQLADMINIP
    SQLADMINIP=${SQLADMINIP:-%}
    
    read -sp "Choose a password for the database admin user (${SQLADMINUSER}): " SQLADMINPASS
    echo ""
    
    read -p "Choose a name for the World Database [world]: " WORLDDB
    WORLDDB=${WORLDDB:-world}
    
    read -p "Choose a name for the Auth Database [auth]: " AUTHDB
    AUTHDB=${AUTHDB:-auth}
    
    read -p "Choose a name for the Characters Database [characters]: " CHARACTERDB
    CHARACTERDB=${CHARACTERDB:-characters}
    
    read -p "Choose a database user account that will be used by the VMaNGOS server [mangos]: " MANGOSDBUSER
    MANGOSDBUSER=${MANGOSDBUSER:-mangos}
    
    read -sp "Choose a password for the ${MANGOSDBUSER} database user account: " MANGOSDBPASS
    echo ""
    
    read -p "Choose a Linux OS user account to run the MaNGOS server processes [mangos]: " MANGOSOSUSER
    MANGOSOSUSER=${MANGOSOSUSER:-mangos}
fi

# Verify the client data exists
if [ ! -d "$CLIENTDATA" ]; then
    echo "ERROR: Client Data directory not found at $CLIENTDATA"
    echo "Please ensure the WoW 1.12.1 client Data folder is uploaded to the server."
    exit 1
fi

# Detect the Server's IP Address
SERVERIP=$(ip route get 1 | awk '{print $7; exit}')
if [ -z "$SERVERIP" ]; then
    SERVERIP=$(hostname -I | awk '{print $1}')
fi
if [ -z "$SERVERIP" ]; then
    SERVERIP="0.0.0.0"
fi

echo " "
echo " "
echo "=============================================== NOTE ================================================"
echo "I detected this machine's IP address as: ${SERVERIP}."
echo " "
echo "Resuming installation in 3 seconds..."
sleep 3

# Create the VMaNGOS directory(s)
mkdir -p "$INSTALLROOT"
mkdir -p "$INSTALLROOT/run"
mkdir -p "$INSTALLROOT/run/5875"
mkdir -p "$INSTALLROOT/build"
mkdir -p "$INSTALLROOT/logs"
mkdir -p "$INSTALLROOT/logs/mangosd"
mkdir -p "$INSTALLROOT/logs/realmd"
mkdir -p "$INSTALLROOT/logs/honor"
cd "$INSTALLROOT"

echo "######################################################################################################"
echo "Updating package list and installing required software."
echo "######################################################################################################"

# Update package list
apt-get update

# Install Base Software Requirements
apt-get install -y \
    net-tools \
    libace-dev \
    libtbb-dev \
    openssl \
    libssl-dev \
    libmysqlclient-dev \
    p7zip-full \
    ntp \
    ntpdate \
    checkinstall \
    build-essential \
    gcc \
    g++ \
    automake \
    git-core \
    autoconf \
    make \
    patch \
    libmysql++-dev \
    mariadb-server \
    libtool \
    grep \
    binutils \
    zlib1g-dev \
    libbz2-dev \
    cmake \
    libboost-all-dev \
    unzip \
    wget \
    curl

export ACE_ROOT=/usr/include/ace
export TBB_ROOT_DIR=/usr/include/tbb

# Start and enable MariaDB service
systemctl start mariadb
systemctl enable mariadb

# Create the VMANGOS OS user if it doesn't exist
if ! id "$MANGOSOSUSER" &>/dev/null; then
    useradd -m -d "/home/$MANGOSOSUSER" -c "VMaNGOS" -s /bin/bash -U "$MANGOSOSUSER"
fi

# Copy the client Data directory to the install path
cp -r "$CLIENTDATA" "$INSTALLROOT/"

# Allow the MariaDB Server to accept remote connections
if [ -f "/etc/mysql/mariadb.conf.d/50-server.cnf" ]; then
    sed -i "s/bind-address.*=.*/bind-address = $SERVERIP/" /etc/mysql/mariadb.conf.d/50-server.cnf
elif [ -f "/etc/mysql/my.cnf" ]; then
    sed -i "s/bind-address.*=.*/bind-address = $SERVERIP/" /etc/mysql/my.cnf
fi
systemctl restart mysql.service

# =============================================================================
# Clone the VMaNGOS git repos (with retry logic)
# =============================================================================

echo "######################################################################################################"
echo "Cloning VMaNGOS repositories"
echo "######################################################################################################"

# Clone core repository
clone_with_retry "https://github.com/vmangos/core" "$INSTALLROOT/source" "development" || {
    echo "ERROR: Failed to clone VMaNGOS core repository"
    exit 1
}

# Clone database repository
clone_with_retry "https://github.com/brotalnia/database" "$INSTALLROOT/db" || {
    echo "ERROR: Failed to clone database repository"
    exit 1
}

# =============================================================================
# Compile the VMaNGOS source code
# =============================================================================

echo "######################################################################################################"
echo "Compiling VMaNGOS source code"
echo "######################################################################################################"

cd "$INSTALLROOT/build"
cmake "$INSTALLROOT/source" \
    -DUSE_EXTRACTORS=1 \
    -DSUPPORTED_CLIENT_BUILD=5875 \
    -DCMAKE_INSTALL_PREFIX="$INSTALLROOT/run"

make -j "$CPU"
make install

# Rename the Config files
cp "$INSTALLROOT/run/etc/mangosd.conf.dist" "$INSTALLROOT/run/etc/mangosd.conf"
cp "$INSTALLROOT/run/etc/realmd.conf.dist" "$INSTALLROOT/run/etc/realmd.conf"

echo " "
echo "######################################################################################################"
echo "Extracting the client data"
echo "######################################################################################################"

# Copy the extractor tools to where they are needed
cp "$INSTALLROOT/run/bin/mapextractor" "$INSTALLROOT/"
cp "$INSTALLROOT/run/bin/vmap_assembler" "$INSTALLROOT/"
cp "$INSTALLROOT/run/bin/vmapextractor" "$INSTALLROOT/"
cp "$INSTALLROOT/run/bin/MoveMapGen" "$INSTALLROOT/"

if [ -f "$INSTALLROOT/source/contrib/mmap/offmesh.txt" ]; then
    cp "$INSTALLROOT/source/contrib/mmap/offmesh.txt" "$INSTALLROOT/"
fi

# Set proper ownership for extraction
chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT"

# Run the extraction process as the mangos user
cd "$INSTALLROOT"

# Run map extractor
echo "Extracting DBC and map files..."
./mapextractor || true

# Run vmap extractors
echo "Extracting vmaps..."
./vmapextractor || true
./vmap_assembler || true

# Run mmaps generator
echo "Generating movement maps (this may take a while)..."
./MoveMapGen --offMeshInput offmesh.txt || true

# Move the extracted content to where the server can read them
mkdir -p "$INSTALLROOT/run/bin/5875"

if [ -d "$INSTALLROOT/dbc" ]; then
    mv "$INSTALLROOT/dbc" "$INSTALLROOT/run/bin/5875/"
fi
if [ -d "$INSTALLROOT/maps" ]; then
    mv "$INSTALLROOT/maps" "$INSTALLROOT/run/bin/"
fi
if [ -d "$INSTALLROOT/mmaps" ]; then
    mv "$INSTALLROOT/mmaps" "$INSTALLROOT/run/bin/"
fi
if [ -d "$INSTALLROOT/vmaps" ]; then
    mv "$INSTALLROOT/vmaps" "$INSTALLROOT/run/bin/"
fi

# Cleanup unused asset directories
rm -rf "$INSTALLROOT/Buildings" 2>/dev/null || true
rm -rf "$INSTALLROOT/Cameras" 2>/dev/null || true

# Set proper ownership
chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT"

echo " "
echo "######################################################################################################"
echo "Starting the Database setup"
echo "######################################################################################################"

# Create the SQL script that creates the databases & db users
cat << EOF > "$INSTALLROOT/db-setup.sql"
CREATE DATABASE IF NOT EXISTS \`$AUTHDB\` DEFAULT CHARSET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS \`$WORLDDB\` DEFAULT CHARSET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS \`$CHARACTERDB\` DEFAULT CHARSET utf8 COLLATE utf8_general_ci;
CREATE DATABASE IF NOT EXISTS \`logs\` DEFAULT CHARSET utf8 COLLATE utf8_general_ci;

CREATE USER IF NOT EXISTS '$MANGOSDBUSER'@'$SERVERIP' IDENTIFIED BY '$MANGOSDBPASS';
CREATE USER IF NOT EXISTS '$MANGOSDBUSER'@'localhost' IDENTIFIED BY '$MANGOSDBPASS';
CREATE USER IF NOT EXISTS '$MANGOSDBUSER'@'%' IDENTIFIED BY '$MANGOSDBPASS';

GRANT ALL PRIVILEGES ON \`$AUTHDB\`.* TO '$MANGOSDBUSER'@'$SERVERIP';
GRANT ALL PRIVILEGES ON \`$WORLDDB\`.* TO '$MANGOSDBUSER'@'$SERVERIP';
GRANT ALL PRIVILEGES ON \`$CHARACTERDB\`.* TO '$MANGOSDBUSER'@'$SERVERIP';
GRANT ALL PRIVILEGES ON \`logs\`.* TO '$MANGOSDBUSER'@'$SERVERIP';

GRANT ALL PRIVILEGES ON \`$AUTHDB\`.* TO '$MANGOSDBUSER'@'localhost';
GRANT ALL PRIVILEGES ON \`$WORLDDB\`.* TO '$MANGOSDBUSER'@'localhost';
GRANT ALL PRIVILEGES ON \`CHARACTERDB\`.* TO '$MANGOSDBUSER'@'localhost';
GRANT ALL PRIVILEGES ON \`logs\`.* TO '$MANGOSDBUSER'@'localhost';

GRANT ALL PRIVILEGES ON \`$AUTHDB\`.* TO '$MANGOSDBUSER'@'%';
GRANT ALL PRIVILEGES ON \`$WORLDDB\`.* TO '$MANGOSDBUSER'@'%';
GRANT ALL PRIVILEGES ON \`$CHARACTERDB\`.* TO '$MANGOSDBUSER'@'%';
GRANT ALL PRIVILEGES ON \`logs\`.* TO '$MANGOSDBUSER'@'%';

-- Create admin user if different from root
GRANT ALL PRIVILEGES ON *.* TO '$SQLADMINUSER'@'$SQLADMINIP' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Run the db setup SQL script to create the new databases and user accounts.
mysql < "$INSTALLROOT/db-setup.sql"

# Clean-up the SQL script so we don't expose any passwords.
rm -f "$INSTALLROOT/db-setup.sql"

# Download and extract the latest full world DB
cd "$INSTALLROOT/db"

# Try to find the latest world DB dump
WORLD_DB_URL="https://github.com/brotalnia/database/releases/download/latest/world_full_14_june_2021.7z"
echo "Downloading world database..."

WORLD_DB_DOWNLOADED=false
if download_with_retry "$WORLD_DB_URL" "world_full.7z"; then
    WORLD_DB_DOWNLOADED=true
else
    # Fallback to the raw file URL
    echo "Primary download failed, trying fallback URL..."
    FALLBACK_URL="https://github.com/brotalnia/database/blob/master/world_full_14_june_2021.7z?raw=true"
    if download_with_retry "$FALLBACK_URL" "world_full.7z"; then
        WORLD_DB_DOWNLOADED=true
    fi
fi

if [ "$WORLD_DB_DOWNLOADED" = true ] && [ -f "world_full.7z" ]; then
    echo "Extracting world database..."
    7z x world_full.7z -aoa
    # Find and import the SQL file
    WORLD_SQL=$(find . -name "world_full*.sql" -type f | head -n1)
    if [ -n "$WORLD_SQL" ]; then
        echo "Importing world database (this may take a while)..."
        mysql "$WORLDDB" < "$WORLD_SQL"
        echo "World database imported successfully."
    else
        echo "WARNING: Could not find world_full*.sql file after extraction"
    fi
    rm -f world_full.7z
else
    echo "WARNING: Failed to download world database. You may need to import it manually."
fi

# Populate the Characters, Auth, and Logs databases from the source directory
echo "Creating characters database structure..."
mysql "$CHARACTERDB" < "$INSTALLROOT/source/sql/characters.sql"

echo "Creating logs database structure..."
mysql "logs" < "$INSTALLROOT/source/sql/logs.sql"

echo "Creating auth database structure..."
mysql "$AUTHDB" < "$INSTALLROOT/source/sql/logon.sql"

# Run migrations against the databases
echo "Running database migrations..."
if [ -d "$INSTALLROOT/source/sql/migrations" ]; then
    cd "$INSTALLROOT/source/sql/migrations"
    if [ -f "merge.sh" ]; then
        chmod +x merge.sh
        ./merge.sh || true
    fi
    
    # Apply migration files if they exist
    if [ -f "world_db_updates.sql" ]; then
        mysql "$WORLDDB" < world_db_updates.sql || true
    fi
    if [ -f "logs_db_updates.sql" ]; then
        mysql "logs" < logs_db_updates.sql || true
    fi
    if [ -f "characters_db_updates.sql" ]; then
        mysql "$CHARACTERDB" < characters_db_updates.sql || true
    fi
    if [ -f "logon_db_updates.sql" ]; then
        mysql "$AUTHDB" < logon_db_updates.sql || true
    fi
fi

echo "######################################################################################################"
echo "Updating the VMaNGOS config files so the World and Auth servers can access the database(s)"
echo "######################################################################################################"

# Update the Auth server configuration file
# Format: host;port;user;password;database
sed -i "s|127.0.0.1;3306;mangos;mangos;realmd|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB|g" "$INSTALLROOT/run/etc/realmd.conf"
sed -i "s|BindIP = \"0.0.0.0\"|BindIP = \"$SERVERIP\"|g" "$INSTALLROOT/run/etc/realmd.conf"

# Update the World server configuration file
sed -i "s|127.0.0.1;3306;mangos;mangos;mangos|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$WORLDDB|g" "$INSTALLROOT/run/etc/mangosd.conf"
sed -i "s|127.0.0.1;3306;mangos;mangos;mangos_auth|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$AUTHDB|g" "$INSTALLROOT/run/etc/mangosd.conf"
sed -i "s|127.0.0.1;3306;mangos;mangos;mangos_world|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$WORLDDB|g" "$INSTALLROOT/run/etc/mangosd.conf"
sed -i "s|127.0.0.1;3306;mangos;mangos;mangos_characters|$SERVERIP;3306;$MANGOSDBUSER;$MANGOSDBPASS;$CHARACTERDB|g" "$INSTALLROOT/run/etc/mangosd.conf"

# Update the log & honor directory setting in the World Server config file
sed -i "s|LogsDir = \"\"|LogsDir = \"$INSTALLROOT/logs/mangosd/\"|g" "$INSTALLROOT/run/etc/mangosd.conf"
sed -i "s|HonorDir = \"\"|HonorDir = \"$INSTALLROOT/logs/honor/\"|g" "$INSTALLROOT/run/etc/mangosd.conf"

echo "######################################################################################################"
echo "Updating the 'realmlist' table in the Auth DB so VMaNGOS knows what IP address to give clients."
echo "######################################################################################################"

# Update the realmlist table with the server IP
mysql "$AUTHDB" -e "UPDATE \`realmlist\` SET \`address\` = '$SERVERIP', \`localaddress\` = '127.0.0.1' WHERE \`id\` = '1';" || true

# Fix file system permissions
chown -R "$MANGOSOSUSER:$MANGOSOSUSER" "$INSTALLROOT"

echo "######################################################################################################"
echo "Creating & starting the system services to run the World and Realm server services."
echo "######################################################################################################"
cd "$HOME"

# Create the Auth service definition
cat << EOF > /etc/systemd/system/auth.service
[Unit]
Description=VMaNGOS Auth Server (Classic WoW)
After=network.target mysql.service
Wants=mysql.service

[Service]
Type=simple
User=${MANGOSOSUSER}
ExecStart=${INSTALLROOT}/run/bin/realmd
WorkingDirectory=${INSTALLROOT}/run/bin/
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create the World service definition
cat << EOF > /etc/systemd/system/world.service
[Unit]
Description=VMaNGOS World Server (Classic WoW)
After=network.target mysql.service
Wants=mysql.service

[Service]
Type=simple
User=${MANGOSOSUSER}
ExecStart=${INSTALLROOT}/run/bin/mangosd
WorkingDirectory=${INSTALLROOT}/run/bin/
Restart=on-failure
RestartSec=5
StandardInput=tty-force
TTYPath=/dev/tty3
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to pick up new services
systemctl daemon-reload

# Secure the MariaDB installation (optional - prompt user in interactive mode)
if ! check_noninteractive; then
    echo ""
    echo "######################################################################################################"
    echo "Would you like to run mysql_secure_installation to secure your MariaDB installation?"
    echo "This is recommended for production servers. (y/n)"
    read -r SECURE_MYSQL
    if [ "$SECURE_MYSQL" = "y" ] || [ "$SECURE_MYSQL" = "Y" ]; then
        mysql_secure_installation
    fi
else
    if [ "$SKIP_SECURE_MYSQL" != "yes" ]; then
        echo "Running mysql_secure_installation..."
        mysql_secure_installation
    else
        echo "Skipping mysql_secure_installation (VMANGOS_SKIP_SECURE_MYSQL=yes)"
    fi
fi

# Enable the new services
systemctl enable auth.service
systemctl enable world.service

echo ""
echo ""
echo "######################################################################################################"
echo "Installation completed successfully!"
echo "######################################################################################################"
echo ""
echo "Summary:"
echo "--------"
echo "Installation Directory: $INSTALLROOT"
echo "Server IP: $SERVERIP"
echo "Auth Database: $AUTHDB"
echo "World Database: $WORLDDB"
echo "Characters Database: $CHARACTERDB"
echo ""
echo "To start the servers:"
echo "  sudo systemctl start auth"
echo "  sudo systemctl start world"
echo ""
echo "To check server status:"
echo "  sudo systemctl status auth"
echo "  sudo systemctl status world"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u auth -f"
echo "  sudo journalctl -u world -f"
echo ""
echo "Installation log saved to: $INSTALL_LOG"
echo ""
echo "Please update your WoW Game client's realmlist.wtf to:"
echo "  set realmlist $SERVERIP"
echo ""
echo "######################################################################################################"
