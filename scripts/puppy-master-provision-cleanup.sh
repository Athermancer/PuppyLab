#!/bin/bash

set -euo pipefail

# ================================
# PuppyLab Master Node Provision + Cleanup Script
# Name: puppy-master-bundle.sh
# Version: 1.2.0
# Description: Clean and provision master node, keeping automation user and system config.
# Author: Miles + ChatGPT
# ================================

LOGFILE="/var/log/puppy-master-bundle.log"

# Ensure logging is in place
if ! command -v ts &>/dev/null; then
    echo "Installing 'moreutils' for timestamped logging..."
    apt update
    apt install -y moreutils
fi

exec > >(ts '[%Y-%m-%d %H:%M:%S] ' | tee -a "$LOGFILE") 2>&1

run_cmd() {
    echo ">>> $*"
    "$@"
}

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# ================================
# Cleanup Step
# ================================

echo "=== Starting cleanup ==="

# Define keep list
KEEP_USERS=("root" "puppy-automation")

echo "Cleaning up users..."
ALL_USERS=$(awk -F: '($3 >= 1000 && $1 != "nobody") { print $1 }' /etc/passwd)

for user in $ALL_USERS; do
    if [[ " ${KEEP_USERS[*]} " == *" $user "* ]]; then
        echo "Keeping user: $user"
    else
        echo "Would you like to delete user '$user'? (yes/No)"
        read -r CONFIRM_DELETE
        if [[ "$CONFIRM_DELETE" == "yes" ]]; then
            echo "Removing user: $user"
            run_cmd pkill -KILL -u "$user" || true
            run_cmd userdel -r "$user" || true
        else
            echo "Skipping user: $user"
        fi
    fi
done

echo "Cleaning up Docker..."

if command -v docker &>/dev/null; then
    docker ps -q | xargs -r docker stop
    docker ps -aq | xargs -r docker rm
    docker volume ls -q | xargs -r docker volume rm
    docker images -q | xargs -r docker rmi -f || true
    docker system prune -af || true
    docker rm -f portainer || true
    docker volume rm portainer_data || true
else
    echo "Docker is not installed. Skipping Docker cleanup."
fi

echo "--- Cleanup Summary ---"
echo "Hostname preserved: $(hostname)"
echo "Static IP preserved."
echo "Automation user preserved: puppy-automation"
echo "Inventory directory preserved at /home/puppy-automation/inventory/"
echo "System is cleaned and ready for provisioning."

# Confirm before running provisioning
echo "Cleanup completed successfully. Would you like to run provisioning now? (yes/No)"
read -r CONFIRM_PROVISION

if [[ "$CONFIRM_PROVISION" == "yes" ]]; then

    echo "=== Starting PuppyLab Master Node provisioning ==="

    NEW_HOSTNAME="docker_master_node"
    run_cmd hostnamectl set-hostname "$NEW_HOSTNAME"
    echo "$NEW_HOSTNAME" > /etc/hostname
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    else
        echo "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    fi

    run_cmd apt update
    run_cmd apt install -y sudo curl apt-transport-https ca-certificates gnupg lsb-release git ansible

    for user in puppy-automation puppydev docker; do
        if id "$user" &>/dev/null; then
            echo "User '$user' already exists. Skipping creation."
        else
            run_cmd useradd -m -s /bin/bash "$user"
            echo "Please set a password for user '$user':"
            run_cmd passwd "$user"
        fi
    done

    for user in puppydev docker; do
        for group in sudo docker; do
            if groups "$user" | grep -qw "$group"; then
                echo "User '$user' already in '$group' group. Skipping."
            else
                run_cmd usermod -aG "$group" "$user"
            fi
        done
    done

    if groups puppy-automation | grep -qw docker; then
        run_cmd gpasswd -d puppy-automation docker || true
    fi

    if ! groups puppy-automation | grep -qw sudo; then
        run_cmd usermod -aG sudo puppy-automation
    fi

    INVENTORY_DIR="/home/puppy-automation/inventory"
    if [[ ! -d "$INVENTORY_DIR" ]]; then
        run_cmd mkdir -p "$INVENTORY_DIR"
        run_cmd chown puppy-automation:puppy-automation "$INVENTORY_DIR"
    fi

    run_cmd mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    run_cmd apt update
    run_cmd apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    run_cmd systemctl enable docker
    run_cmd systemctl start docker

    run_cmd docker volume create portainer_data
    run_cmd docker run -d -p 9443:9443 --name portainer --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data portainer/portainer-ce:latest

    # Network configuration prompt
    PRIMARY_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
    CURRENT_IP=$(ip -o -4 addr show "$PRIMARY_INTERFACE" | awk '{print $4}')
    CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}')
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)

    echo "--- Current Network Settings ---"
    echo "Interface: $PRIMARY_INTERFACE"
    echo "IP Address: $CURRENT_IP"
    echo "Gateway: $CURRENT_GATEWAY"
    echo "DNS Servers: $CURRENT_DNS"

    echo "Do you want to keep the current network configuration? (yes/No)"
    read -r KEEP_NETWORK

    if [[ "$KEEP_NETWORK" == "yes" ]]; then
        STATIC_IP="$CURRENT_IP"
        GATEWAY="$CURRENT_GATEWAY"
        DNS_SERVERS="$CURRENT_DNS"
    else
        echo "Enter desired static IP address (e.g., 192.168.1.100/24): "
        read -r STATIC_IP

        echo "Enter gateway (e.g., 192.168.1.1): "
        read -r GATEWAY

        echo "Enter DNS servers (comma separated, e.g., 1.1.1.1,8.8.8.8): "
        read -r DNS_SERVERS
    fi

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

    run_cmd systemctl enable systemd-networkd
    run_cmd systemctl restart systemd-networkd

    cat <<EOF > /usr/local/bin/remove-bootstrap-user.sh
#!/bin/bash
if id "bootstrap" &>/dev/null; then
    echo "Removing 'bootstrap' user..."
    pkill -KILL -u "bootstrap" || true
    userdel -r "bootstrap" || true
else
    echo "'bootstrap' user does not exist. Skipping."
fi
systemctl disable remove-bootstrap-user.service
rm -f /usr/local/bin/remove-bootstrap-user.sh
EOF

    chmod +x /usr/local/bin/remove-bootstrap-user.sh

    cat <<EOF > /etc/systemd/system/remove-bootstrap-user.service
[Unit]
Description=Remove 'bootstrap' user after provisioning
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/remove-bootstrap-user.sh

[Install]
WantedBy=multi-user.target
EOF

    run_cmd systemctl enable remove-bootstrap-user.service

    echo "--- Provisioning Summary ---"
    echo "Hostname: $NEW_HOSTNAME"
    echo "Static IP: $STATIC_IP"
    echo "Automation User: puppy-automation (NO Docker access)"
    echo "Users created: puppy-automation, puppydev, docker"
    echo "Inventory Directory: $INVENTORY_DIR"
    echo "Docker: Installed"
    echo "Portainer: Installed on port 9443"
    echo "Ansible: Installed"

else
    echo "Provisioning skipped. Cleanup complete."
fi

# Final reboot prompt
echo "Do you want to reboot the system now? (yes/no): "
read -r REBOOT_CONFIRMATION
if [[ "$REBOOT_CONFIRMATION" == "yes" ]]; then
    echo "Rebooting system..."
    run_cmd systemctl reboot
else
    echo "Reboot canceled. Please reboot manually to apply all changes."
fi
