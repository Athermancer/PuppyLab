#!/bin/bash

set -euo pipefail

# ================================
# PuppyLab Master Node Provision + Cleanup Script
# Name: puppy-master-bundle.sh
# Version: 1.4.0
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
            run_cmd deluser --remove-home "$user" || true
        else
            echo "Skipping user: $user"
        fi
    fi
done

# Clean up orphaned groups
echo "Cleaning up orphaned groups..."
ALL_GROUPS=$(awk -F: '($3 >= 1000) { print $1 }' /etc/group)
for group in $ALL_GROUPS; do
    MEMBERS=$(getent group "$group" | awk -F: '{print $4}')
    if [[ -z "$MEMBERS" ]]; then
        echo "Removing orphaned group: $group"
        run_cmd delgroup "$group" || true
    fi
done

# Clean up Docker...
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

cat <<EOF > /usr/local/bin/remove-bootstrap-user.sh
#!/bin/bash
if id "bootstrap" &>/dev/null; then
    echo "Removing 'bootstrap' user..."
    pkill -KILL -u "bootstrap" || true
    deluser --remove-home "bootstrap" || true
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
echo "--- Cleanup Summary ---"
echo "Hostname preserved: $(hostname)"
echo "Automation user preserved: puppy-automation"
echo "Inventory directory preserved at /home/puppy-automation/inventory/"
echo "System cleaned. Ready for provisioning."

# Confirm before provisioning
echo "Cleanup completed successfully. Would you like to run provisioning now? (yes/No)"
read -r CONFIRM_PROVISION

if [[ "$CONFIRM_PROVISION" == "yes" ]]; then
    echo "=== Provisioning not included in this segment. ==="
    echo "(Full provisioning steps continue in the complete script.)"
else
    echo "Provisioning skipped. Cleanup complete."
fi

# Reboot prompt
echo "Do you want to reboot the system now? (yes/no): "
read -r REBOOT_CONFIRMATION
if [[ "$REBOOT_CONFIRMATION" == "yes" ]]; then
    echo "Rebooting system..."
    run_cmd systemctl reboot
else
    echo "Reboot canceled. Please reboot manually to apply all changes."
fi
