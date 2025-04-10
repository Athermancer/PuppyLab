#!/bin/bash

set -euo pipefail

# ================================
# PuppyLab Master Node Provisioning Script
# Name: puppy-master-bootstrap.sh
# Version: 1.2.0
# Description: Provision Master Node with Docker, Portainer, Ansible, and automation user.
# Author: Miles + ChatGPT
# ================================

LOGFILE="/var/log/puppy-master-bootstrap.log"

# Ensure logging is in place
if ! command -v ts &>/dev/null; then
    echo "Installing 'moreutils' for timestamped logging..."
    apt update
    apt install -y moreutils
fi

exec > >(ts '[%Y-%m-%d %H:%M:%S] ' | tee -a "$LOGFILE") 2>&1

echo "=== Starting PuppyLab Master Node provisioning script v1.2.0 ==="

run_cmd() {
    echo ">>> $*"
    "$@"
}

# Early sudo/root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# Set static hostname
NEW_HOSTNAME="docker_master_node"
echo "Setting hostname to '$NEW_HOSTNAME'..."
run_cmd hostnamectl set-hostname "$NEW_HOSTNAME"
echo "$NEW_HOSTNAME" > /etc/hostname
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
fi

# Install essentials
echo "Installing essential packages..."
run_cmd apt update
run_cmd apt install -y sudo curl apt-transport-https ca-certificates gnupg lsb-release git ansible

# Create users: puppy-automation, puppydev, docker
for user in puppy-automation puppydev docker; do
    if id "$user" &>/dev/null; then
        echo "User '$user' already exists. Skipping creation."
    else
        echo "Creating user '$user'..."
        run_cmd useradd -m -s /bin/bash "$user"
        echo "Please set a password for user '$user':"
        run_cmd passwd "$user"
    fi
done

# Group assignments
for user in puppydev docker; do
    for group in sudo docker; do
        if groups "$user" | grep -qw "$group"; then
            echo "User '$user' already in '$group' group. Skipping."
        else
            run_cmd usermod -aG "$group" "$user"
        fi
    done
done

# Ensure puppy-automation user is ONLY in sudo group (remove from docker if exists)
if groups puppy-automation | grep -qw docker; then
    echo "Removing 'puppy-automation' user from 'docker' group..."
    gpasswd -d puppy-automation docker || true
fi

if groups puppy-automation | grep -qw sudo; then
    echo "'puppy-automation' user already in 'sudo' group. Skipping."
else
    run_cmd usermod -aG sudo puppy-automation
fi

# Prepare inventory folder
INVENTORY_DIR="/home/puppy-automation/inventory"
echo "Preparing inventory directory at '$INVENTORY_DIR'..."
if [[ -d "$INVENTORY_DIR" ]]; then
    echo "Inventory directory already exists. Skipping."
else
    run_cmd mkdir -p "$INVENTORY_DIR"
    run_cmd chown puppy-automation:puppy-automation "$INVENTORY_DIR"
fi

# Install Docker
echo "Installing Docker..."
run_cmd mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "Adding Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

run_cmd apt update
run_cmd apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

run_cmd systemctl enable docker
run_cmd systemctl start docker

# Install Portainer
echo "Installing Portainer..."
run_cmd docker volume create portainer_data
run_cmd docker run -d -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest

# Configure network
echo "Configuring static network settings..."
PRIMARY_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
NETWORK_CONFIG_DIR="/etc/systemd/network"
NETWORK_CONFIG_FILE="$NETWORK_CONFIG_DIR/20-wired.network"
STATIC_IP="192.168.4.211"
GATEWAY="$(ip route | grep default | awk '{print $3}')"
DNS_SERVERS="1.1.1.1,8.8.8.8"

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

# Remove bootstrap user after reboot
echo "Scheduling removal of 'bootstrap' user after reboot..."
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

# Final summary
echo "--- Final Summary ---"
echo "Hostname: $NEW_HOSTNAME"
echo "Static IP: $STATIC_IP"
echo "Automation User: puppy-automation (NO Docker access)"
echo "Users created: puppy-automation, puppydev, docker"
echo "Inventory Directory: $INVENTORY_DIR"
echo "Docker: Installed"
echo "Portainer: Installed on port 9443"
echo "Ansible: Installed"
echo "Reboot required to apply all changes."

# Reboot prompt
echo "Do you want to reboot the system now? (yes/no): "
read -r REBOOT_CONFIRMATION
if [[ "$REBOOT_CONFIRMATION" == "yes" ]]; then
    echo "Rebooting system..."
    run_cmd systemctl reboot
else
    echo "Reboot canceled. Please reboot manually to apply all changes."
fi
