#!/bin/bash

set -euo pipefail

# ================================
# PuppyLab Provisioning Script
# Name: puppy-bootstrap.sh
# Version: 1.1.3
# Description: Provision Debian server with users, Docker, network config, and cleanup.
# Author: Miles + ChatGPT
# ================================

LOGFILE="/var/log/puppy-bootstrap.log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "=== Starting PuppyLab bootstrap provisioning script v1.1.3 ==="

run_cmd() {
    echo ">>> $*"
    "$@"
}

# === Dry run mode ===
read -rp "Do you want to enable DRY RUN mode? (yes/no): " DRY_RUN_CONFIRMATION
if [[ "$DRY_RUN_CONFIRMATION" == "yes" ]]; then
    DRY_RUN=true
    echo "Dry run mode enabled. No users will be actually deleted."
else
    DRY_RUN=false
    echo "Dry run mode disabled. Users will be deleted if not in whitelist."
fi

# === Hostname setup ===
set_hostname_with_input() {
    echo "--- Setting system hostname ---"

    while true; do
        read -rp "Enter node number for this system (e.g., 1, 2, 3): " NODE_NUMBER
        if [[ "$NODE_NUMBER" =~ ^[0-9]+$ ]]; then
            break
        else
            echo "Invalid number. Please enter a numeric value."
        fi
    done

    NEW_HOSTNAME="docker_node_$NODE_NUMBER"

    echo "Assigning hostname: $NEW_HOSTNAME"
    run_cmd hostnamectl set-hostname "$NEW_HOSTNAME"
    echo "$NEW_HOSTNAME" > /etc/hostname

    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    else
        echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
    fi

    echo "Hostname set to '$NEW_HOSTNAME'."
}

set_hostname_with_input

# === Install essentials ===
echo "--- Installing sudo and required packages..."
run_cmd apt update
run_cmd apt install -y sudo curl apt-transport-https ca-certificates gnupg lsb-release

# === User creation ===
if id "puppydev" &>/dev/null; then
    echo "User 'puppydev' already exists. Skipping creation."
else
    echo "--- Creating 'puppydev' user..."
    run_cmd useradd -m -s /bin/bash puppydev
    echo "Please set a password for 'puppydev':"
    run_cmd passwd puppydev
fi

if id "docker" &>/dev/null; then
    echo "User 'docker' already exists. Skipping creation."
else
    echo "--- Creating 'docker' user..."
    run_cmd useradd -m -s /bin/bash docker
fi

# === Group assignments ===
echo "--- Adding users to groups if needed..."
for user in puppydev docker; do
    if groups $user | grep -qw "sudo"; then
        echo "User '$user' already in 'sudo' group. Skipping."
    else
        run_cmd usermod -aG sudo $user
    fi

    if groups $user | grep -qw "docker"; then
        echo "User '$user' already in 'docker' group. Skipping."
    else
        run_cmd usermod -aG docker $user
    fi
done

# === Install Docker ===
echo "--- Installing Docker..."
run_cmd mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "Adding Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

run_cmd apt update

echo "Do you want to install Docker plugins (buildx and compose)? (yes/no):"
read -r INSTALL_PLUGINS
if [[ "$INSTALL_PLUGINS" == "yes" ]]; then
    run_cmd apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    run_cmd apt install -y docker-ce docker-ce-cli containerd.io
fi

run_cmd systemctl enable docker
run_cmd systemctl start docker

# === Directories ===
echo "--- Creating Docker project directories if they do not exist..."

create_dir_if_missing() {
    DIR_PATH="$1"
    OWNER="$2"

    if [[ -d "$DIR_PATH" ]]; then
        echo "Directory '$DIR_PATH' already exists. Skipping."
    else
        run_cmd mkdir -p "$DIR_PATH"
        run_cmd chown "$OWNER":"$OWNER" "$DIR_PATH"
        echo "Created directory '$DIR_PATH' with owner '$OWNER'."
    fi
}

create_dir_if_missing /opt/docker-projects puppydev
create_dir_if_missing /home/docker/docker-projects docker
create_dir_if_missing /home/puppydev/docker-projects puppydev

# === Clean bootstrap user ===
BOOTSTRAP_USER=$(logname || echo "unknown")
if [[ "$BOOTSTRAP_USER" != "root" && "$BOOTSTRAP_USER" != "unknown" && "$BOOTSTRAP_USER" != "puppydev" && "$BOOTSTRAP_USER" != "docker" ]]; then
    echo "--- Removing bootstrap user '$BOOTSTRAP_USER'..."
    run_cmd pkill -KILL -u "$BOOTSTRAP_USER" || true
    run_cmd userdel -r "$BOOTSTRAP_USER" || true
else
    echo "No bootstrap user to remove or user is system-reserved."
fi

# === Clean up unexpected users ===
echo "--- Cleaning up unexpected users..."

WHITELIST=("root" "puppydev" "docker")

ALL_USERS=$(awk -F: '($3 >= 1000) { print $1 }' /etc/passwd)

for USER in $ALL_USERS; do
    if [[ " ${WHITELIST[*]} " != *" $USER "* ]]; then
        echo "User '$USER' is not in whitelist."
        if [[ "$DRY_RUN" == true ]]; then
            echo "[DRY RUN] Would remove: $USER"
        else
            echo "Removing unexpected user: $USER"
            run_cmd pkill -KILL -u "$USER" || true
            run_cmd userdel -r "$USER" || true
        fi
    else
        echo "Keeping user: $USER"
    fi
done

echo "User cleanup complete."

# === Static IP configuration ===
echo "--- Static IP configuration ---"

PRIMARY_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
echo "Detected primary interface: $PRIMARY_INTERFACE"

while true; do
    read -rp "Enter desired static IP address (e.g., 192.168.1.100/24): " STATIC_IP
    if [[ "$STATIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        break
    else
        echo "Invalid static IP format. Please try again."
    fi
done

while true; do
    read -rp "Enter gateway (e.g., 192.168.1.1): " GATEWAY
    if [[ "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    else
        echo "Invalid gateway format. Please try again."
    fi
done

while true; do
    read -rp "Enter DNS servers (comma separated, e.g., 1.1.1.1,8.8.8.8): " DNS_SERVERS
    if [[ "$DNS_SERVERS" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(,[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$ ]]; then
        break
    else
        echo "Invalid DNS servers format. Please try again."
    fi
done

NETWORK_CONFIG_DIR="/etc/systemd/network"
NETWORK_CONFIG_FILE="$NETWORK_CONFIG_DIR/20-wired.network"

mkdir -p "$NETWORK_CONFIG_DIR"

cat > "$NETWORK_CONFIG_FILE" <<EOF
[Match]
Name=$PRIMARY_INTERFACE

[Network]
Address=$STATIC_IP
Gateway=$GATEWAY
DNS=$DNS_SERVERS
EOF

echo "Network configuration written to $NETWORK_CONFIG_FILE"

run_cmd systemctl enable systemd-networkd
run_cmd systemctl restart systemd-networkd

echo "Static IP configuration applied."

echo "=== PuppyLab bootstrap provisioning v1.1.3 completed successfully! ==="

read -rp "Do you want to reboot the system now? (yes/no): " REBOOT_CONFIRMATION
if [[ "$REBOOT_CONFIRMATION" == "yes" ]]; then
    echo "Rebooting system..."
    run_cmd reboot
else
    echo "Reboot canceled. Please reboot manually to apply all changes."
fi
