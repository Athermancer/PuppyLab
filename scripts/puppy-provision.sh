#!/bin/bash

set -euo pipefail

# ================================
# PuppyLab Provisioning Script
# Name: puppy-bootstrap.sh
# Version: 1.2.1
# Description: Provision Debian server with users, Docker, network config, and cleanup after reboot.
# Author: Miles + ChatGPT
# ================================

LOGFILE="/var/log/puppy-bootstrap.log"

# === Ensure required packages for logging ===
echo "--- Checking for required packages..."

if ! command -v ts &>/dev/null; then
    echo "Installing 'moreutils' for timestamped logging..."
    apt update
    apt install -y moreutils
else
    echo "'moreutils' already installed. Good to go."
fi

# Start logging with timestamps
exec > >(ts '[%Y-%m-%d %H:%M:%S] ' | tee -a "$LOGFILE") 2>&1

echo "=== Starting PuppyLab bootstrap provisioning script v1.2.1 ==="

run_cmd() {
    echo ">>> $*"
    "$@"
}

# === Dry run mode ===
DRY_RUN=false

echo "--- Checking dry-run mode ---"
echo -n "Do you want to enable DRY RUN mode? (yes/no): " >&2
read -r DRY_RUN_CONFIRMATION
if [[ "$DRY_RUN_CONFIRMATION" == "yes" ]]; then
    DRY_RUN=true
    echo "Dry run mode enabled. No users or configurations will be modified."
else
    DRY_RUN=false
    echo "Dry run mode disabled. System changes will be applied."
fi

# === Hostname setup ===
set_hostname_with_input() {
    echo "--- Setting system hostname ---"

    while true; do
        echo -n "Enter node number for this system (e.g., 1, 2, 3): " >&2
        read -r NODE_NUMBER
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
for user in puppydev docker; do
    if id "$user" &>/dev/null; then
        echo "User '$user' already exists. Skipping creation."
    else
        echo "--- Creating user '$user'..."
        run_cmd useradd -m -s /bin/bash "$user"
        echo "Please set a password for user '$user':"
        run_cmd passwd "$user"
    fi
done

# === Group assignments ===
echo "--- Adding users to groups if needed..."
for user in puppydev docker; do
    for group in sudo docker; do
        if groups $user | grep -qw "$group"; then
            echo "User '$user' already in '$group' group. Skipping."
        else
            run_cmd usermod -aG "$group" "$user"
        fi
    done
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

# === Network Configuration ===
echo "--- Network configuration ---"

PRIMARY_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
echo "Detected primary interface: $PRIMARY_INTERFACE"

# Prompt for IP config
echo -n "Do you want to keep existing IP configuration? (yes/no): " >&2
read -r KEEP_IP

NETWORK_CONFIG_DIR="/etc/systemd/network"
NETWORK_CONFIG_FILE="$NETWORK_CONFIG_DIR/20-wired.network"

if [[ "$KEEP_IP" == "yes" ]]; then
    echo "Keeping existing network configuration."
else
    while true; do
        echo -n "Enter desired static IP address (e.g., 192.168.1.100/24): " >&2
        read -r STATIC_IP
        if [[ "$STATIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            break
        else
            echo "Invalid static IP format. Please try again."
        fi
    done

    while true; do
        echo -n "Enter gateway (e.g., 192.168.1.1): " >&2
        read -r GATEWAY
        if [[ "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo "Invalid gateway format. Please try again."
        fi
    done

    while true; do
        echo -n "Enter DNS servers (comma separated, e.g., 1.1.1.1,8.8.8.8): " >&2
        read -r DNS_SERVERS
        if [[ "$DNS_SERVERS" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(,[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$ ]]; then
            break
        else
            echo "Invalid DNS servers format. Please try again."
        fi
    done

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
fi

# === Plan removal of bootstrap user ===
CURRENT_USER=$(whoami)
WHITELIST=("root" "puppydev" "docker" "daemon")

if [[ ! " ${WHITELIST[*]} " =~ " $CURRENT_USER " ]]; then
    echo "--- Scheduling removal of temporary user '$CURRENT_USER' after reboot..."

    # Create cleanup script
    cat <<EOF > /usr/local/bin/remove-temp-user.sh
#!/bin/bash
if id "$CURRENT_USER" &>/dev/null; then
    echo "Removing temporary user: $CURRENT_USER"
    pkill -KILL -u "$CURRENT_USER" || true
    userdel -r "$CURRENT_USER" || true
else
    echo "User '$CURRENT_USER' does not exist. Skipping."
fi
systemctl disable remove-temp-user.service
rm -f /usr/local/bin/remove-temp-user.sh
EOF

    chmod +x /usr/local/bin/remove-temp-user.sh

    # Create systemd service
    cat <<EOF > /etc/systemd/system/remove-temp-user.service
[Unit]
Description=Remove temporary user after provisioning
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/remove-temp-user.sh

[Install]
WantedBy=multi-user.target
EOF

    run_cmd systemctl enable remove-temp-user.service

else
    echo "Current user '$CURRENT_USER' is whitelisted. No removal scheduled."
fi

# === Check and delete non-whitelisted users ===
echo "--- Checking for non-whitelisted users to delete ---"

# List all users excluding the whitelisted ones
ALL_USERS=$(getent passwd | cut -d: -f1)
NON_WHITELISTED_USERS=""

for user in $ALL_USERS; do
    if [[ ! " ${WHITELIST[*]} " =~ " $user " ]]; then
        NON_WHITELISTED_USERS+="$user "
    fi
done

# Prompt user to delete each non-whitelisted user
for user in $NON_WHITELISTED_USERS; do
    echo "--------------------------------------------"
    read -rp "Do you want to delete user '$user'? (yes/no/skip): " DELETE_USER_CONFIRMATION
    if [[ "$DELETE_USER_CONFIRMATION" == "yes" ]]; then
        echo "Deleting user '$user'..."
        run_cmd userdel -r "$user" || true
    elif [[ "$DELETE_USER_CONFIRMATION" == "skip" ]]; then
        echo "Skipping user '$user'."
    fi
done

# === Final summary ===
echo "--- Final Summary ---"
echo "Hostname: $NEW_HOSTNAME"
echo "Static IP: $STATIC_IP"
echo "Users created: puppydev, docker"
echo "User cleanup scheduled for: $CURRENT_USER (if not whitelisted)"
echo "Reboot required to apply all changes."

# === Reboot prompt ===
read -rp "Do you want to reboot the system now? (yes/no): " REBOOT_CONFIRMATION
if [[ "$REBOOT_CONFIRMATION" == "yes" ]]; then
    echo "Rebooting system..."
    run_cmd systemctl reboot
else
    echo "Reboot canceled. Please reboot manually to apply all changes."
fi
