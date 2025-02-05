#!/bin/bash

# Exit on any error
set -e

# Define color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script version
VERSION="2.0.0"

# Track completed steps
STEPS_FILE="/tmp/server_setup_progress"

# Function to print colored messages
print_message() {
    local level=$1
    local message=$2
    case $level in
        "info")  echo -e "${GREEN}[INFO] $message${NC}" ;;
        "warn")  echo -e "${YELLOW}[WARN] $message${NC}" ;;
        "error") echo -e "${RED}[ERROR] $message${NC}" ;;
    esac
}

# Function to get user input with validation
get_input() {
    local prompt=$1
    local var_name=$2
    local default=$3
    local value=""

    while [ -z "$value" ]; do
        if [ -n "$default" ]; then
            read -p "$prompt [$default]: " value
            value=${value:-$default}
        else
            read -p "$prompt: " value
        fi

        if [ -z "$value" ]; then
            print_message "warn" "Value cannot be empty"
        fi
    done
    
    eval "$var_name=\"$value\""
}

# Function to mark step as completed
mark_step_complete() {
    echo "$1" >> "$STEPS_FILE"
}

# Function to check if step is completed
is_step_completed() {
    if [ -f "$STEPS_FILE" ]; then
        grep -q "^$1\$" "$STEPS_FILE"
        return $?
    fi
    return 1
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_message "error" "Please run this script as root or with sudo"
        exit 1
    fi
}

# Function to get configuration variables
get_config() {
    print_message "info" "Please enter the configuration details"
    
    # Get username
    get_input "Enter the username for the new user" "USERNAME"
    
    # Get SSH port
    get_input "Enter the SSH port" "SSH_PORT" "22"
    
    # Get monitoring repository
    get_input "Enter the monitoring scripts repository URL" "MONITORING_REPO" "https://github.com/yourgithub/monitoring-scripts"
    
    # Get script names
    get_input "Enter the security monitoring script name" "SECURITY_SCRIPT" "security-monitor.sh"
    get_input "Enter the server monitoring script name" "SERVER_SCRIPT" "server-monitor.sh"
    
    # Get webhook URLs
    get_input "Enter Discord webhook URL for server monitoring" "MONITORING_WEBHOOK_URL"
    get_input "Enter Discord webhook URL for security monitoring" "SECURITY_WEBHOOK_URL"
    
    # Get monitoring thresholds
    get_input "Enter CPU usage alert threshold (%)" "ALERT_THRESHOLD_CPU" "80"
    get_input "Enter memory usage alert threshold (%)" "ALERT_THRESHOLD_MEM" "80"
    get_input "Enter disk usage alert threshold (%)" "ALERT_THRESHOLD_DISK" "85"
}

# Function to set up new user
setup_user() {
    if is_step_completed "user_setup"; then
        print_message "info" "User $USERNAME already exists, skipping user creation"
        return 0
    fi

    print_message "info" "Creating user: $USERNAME"
    adduser --gecos "" "$USERNAME" || return 1

    # Ensure user is in sudo group
    usermod -aG sudo "$USERNAME" || return 1

    mark_step_complete "user_setup"
    print_message "info" "User setup completed"
}

# Function to test monitoring setup
test_monitoring() {
    local script_path=$1
    local script_name=$(basename "$script_path")
    
    print_message "info" "Testing $script_name..."
    
    # Run the script as the new user
    if sudo -u "$USERNAME" /bin/bash "$script_path" --test; then
        print_message "info" "✅ $script_name executed successfully"
        
        # Check if Discord message was sent (look for success log)
        if sudo -u "$USERNAME" grep -q "Discord notification sent successfully" /tmp/monitoring_test.log 2>/dev/null; then
            print_message "info" "✅ Discord notification was sent successfully"
        else
            print_message "warn" "⚠️  Could not confirm if Discord notification was sent"
            print_message "info" "Please check your Discord channel for messages"
        fi
    else
        print_message "error" "❌ $script_name failed to execute"
        print_message "error" "Check the script output above for errors"
        return 1
    fi
}

# Modified setup_monitoring function
setup_monitoring() {
    if is_step_completed "monitoring_setup"; then
        print_message "info" "Monitoring already configured, skipping"
        return 0
    fi

    print_message "info" "Setting up monitoring scripts..."
    
    # Create monitoring directory with proper ownership
    mkdir -p /opt/monitoring
    chown "$USERNAME:$USERNAME" /opt/monitoring
    
    # Switch to the monitoring directory
    cd /opt/monitoring
    
    # Download monitoring scripts as the new user
    sudo -u "$USERNAME" curl -O "${MONITORING_REPO}/${SECURITY_SCRIPT}"
    sudo -u "$USERNAME" curl -O "${MONITORING_REPO}/${SERVER_SCRIPT}"
    
    # Set executable permissions
    chmod +x "${SECURITY_SCRIPT}" "${SERVER_SCRIPT}"
    chown "$USERNAME:$USERNAME" "${SECURITY_SCRIPT}" "${SERVER_SCRIPT}"
    
    # Create .env file with collected settings
    print_message "info" "Creating environment file..."
    cat > /opt/monitoring/.env <<EOF
# Server monitoring settings
MONITORING_WEBHOOK_URL=${MONITORING_WEBHOOK_URL}
ALERT_THRESHOLD_CPU=${ALERT_THRESHOLD_CPU}
ALERT_THRESHOLD_MEM=${ALERT_THRESHOLD_MEM}
ALERT_THRESHOLD_DISK=${ALERT_THRESHOLD_DISK}

# Security monitoring settings
SECURITY_WEBHOOK_URL=${SECURITY_WEBHOOK_URL}
EOF

    # Set proper permissions for .env file
    chown "$USERNAME:$USERNAME" /opt/monitoring/.env
    chmod 600 /opt/monitoring/.env
    
    # Test both monitoring scripts
    print_message "info" "Testing monitoring setup..."
    print_message "info" "This will send test notifications to your Discord channels"
    
    # Test server monitoring
    test_monitoring "/opt/monitoring/${SERVER_SCRIPT}"
    server_test_result=$?
    
    # Test security monitoring
    test_monitoring "/opt/monitoring/${SECURITY_SCRIPT}"
    security_test_result=$?
    
    # Add cronjobs only if tests passed
    if [ $server_test_result -eq 0 ] && [ $security_test_result -eq 0 ]; then
        print_message "info" "Setting up cron jobs..."
        sudo -u "$USERNAME" bash -c '
            (crontab -l 2>/dev/null | grep -v "'${SECURITY_SCRIPT}'"; echo "*/15 * * * * /opt/monitoring/'${SECURITY_SCRIPT}'") | sort -u | crontab -
            (crontab -l 2>/dev/null | grep -v "'${SERVER_SCRIPT}'"; echo "*/5 * * * * /opt/monitoring/'${SERVER_SCRIPT}'") | sort -u | crontab -
        '
        print_message "info" "✅ Cron jobs set up successfully"
    else
        print_message "error" "❌ Monitoring tests failed - please check the errors above"
        print_message "error" "Cron jobs were NOT set up due to test failures"
        return 1
    fi
    
    mark_step_complete "monitoring_setup"
    print_message "info" "Monitoring setup completed successfully!"
}

# Function to set up SSH security
configure_ssh() {
    if is_step_completed "ssh_setup"; then
        print_message "info" "SSH already configured, skipping"
        return 0
    fi

    print_message "info" "Configuring SSH..."
    
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)
    
    # Configure SSH daemon
    cat > /etc/ssh/sshd_config <<EOF
Port ${SSH_PORT}
Protocol 2
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 60
AllowUsers ${USERNAME}

Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    # Set up user SSH directory and keys
    print_message "info" "Setting up SSH directory for ${USERNAME}"
    
    # Create .ssh directory if it doesn't exist
    if [ ! -d "/home/${USERNAME}/.ssh" ]; then
        mkdir -p "/home/${USERNAME}/.ssh"
    fi
    
    # Create authorized_keys file if it doesn't exist
    touch "/home/${USERNAME}/.ssh/authorized_keys"
    
    # Set correct permissions
    chmod 700 "/home/${USERNAME}/.ssh"
    chmod 600 "/home/${USERNAME}/.ssh/authorized_keys"
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.ssh"
    
    # If root has authorized_keys, copy them to the new user
    if [ -f "/root/.ssh/authorized_keys" ]; then
        print_message "info" "Copying root's authorized keys to ${USERNAME}"
        cat "/root/.ssh/authorized_keys" >> "/home/${USERNAME}/.ssh/authorized_keys"
    else
        print_message "warn" "No authorized_keys found in root directory"
        print_message "info" "Remember to add your SSH public key to: /home/${USERNAME}/.ssh/authorized_keys"
        print_message "info" "You can do this by running: ssh-copy-id -i ~/.ssh/id_ed25519.pub ${USERNAME}@<server-ip>"
    fi
    
    # Restart SSH service
    systemctl restart ssh
    
    mark_step_complete "ssh_setup"
    
    # Print SSH setup completion message
    print_message "info" "SSH configuration completed"
    print_message "info" "Make sure to add your SSH public key before logging out!"
    print_message "info" "Current SSH port: ${SSH_PORT}"
}

# Function to set up basic security
setup_security() {
    if is_step_completed "security_setup"; then
        print_message "info" "Security measures already configured, skipping"
        return 0
    fi

    print_message "info" "Setting up security measures..."
    
    # UFW Setup
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ${SSH_PORT}/tcp comment 'SSH'
    ufw --force enable
    
    # Fail2ban Setup
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
EOF
    
    systemctl enable fail2ban
    systemctl restart fail2ban
    mark_step_complete "security_setup"
}

# Function to install and configure Cloudflared
setup_cloudflared() {
    if is_step_completed "cloudflared_install"; then
        print_message "info" "Cloudflared already installed, skipping installation"
    else
        print_message "info" "Installing Cloudflared..."
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
        dpkg -i cloudflared.deb
        rm cloudflared.deb
        mark_step_complete "cloudflared_install"
    fi
    
    if is_step_completed "cloudflared_setup"; then
        print_message "info" "Cloudflared already configured, skipping setup"
        return 0
    fi

    # Create directory for cert
    mkdir -p /home/"$USERNAME"/.cloudflared
    chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"/.cloudflared
    
    # Check for cert.pem in user directory
    if [ ! -f "/home/$USERNAME/.cloudflared/cert.pem" ]; then
        print_message "warn" "Cloudflare authentication required! You need to log in:"
        print_message "info" "1. Press Ctrl+Z to suspend this script, then:"
        print_message "info" "   - Run 'cloudflared login'"
        print_message "info" "   - After login completes, type 'fg' to resume this script"
        read -p "Have you completed cloudflared login? (y/n): " answer
        if [[ "$answer" != "y" ]]; then
            print_message "info" "Please complete the login step and run the script again"
            exit 0
        fi
    fi
    
    # Create a new tunnel with the server's hostname
    server_hostname=$(hostname)  # Get the actual server hostname
    print_message "info" "Creating new tunnel for server hostname: $server_hostname"
    cloudflared tunnel create "$server_hostname"
    
    # Find the generated credentials file
    tunnel_id=$(cloudflared tunnel list | grep "$server_hostname" | awk '{print $1}')
    credentials_file="/home/$USERNAME/.cloudflared/$tunnel_id.json"
    
    if [ ! -f "$credentials_file" ]; then
        print_message "error" "Tunnel credentials file not found!"
        exit 1
    fi

    # Create Cloudflared config.yml with tunnel info
    print_message "info" "Creating cloudflared config.yml..."
    sudo bash -c "cat > /etc/cloudflared/config.yml <<EOL
tunnel: $tunnel_id
credentials-file: $credentials_file
ingress:
  - hostname: $server_hostname   # Use server hostname here
    service: http://localhost:80
  - service: http_status:404
EOL"

    # Start Cloudflared service
    cloudflared service install
    systemctl enable cloudflared
    systemctl start cloudflared
    
    mark_step_complete "cloudflared_setup"
}

# Function to update system packages
update_system() {
    if is_step_completed "system_update"; then
        print_message "info" "System already updated, skipping"
        return 0
    fi

    print_message "info" "Updating system packages..."
    apt update && apt upgrade -y
    mark_step_complete "system_update"
}

# Function to install essential packages
install_essentials() {
    if is_step_completed "essentials_install"; then
        print_message "info" "Essential packages already installed, skipping"
        return 0
    fi

    print_message "info" "Installing essential packages..."
    apt install -y \
        curl \
        wget \
        git \
        htop \
        ufw \
        fail2ban \
        net-tools \
        sudo \
        unzip \
        jq
    
    mark_step_complete "essentials_install"
}

# Main function
main() {
    check_root
    get_config
    
    print_message "info" "Starting server setup (v${VERSION})..."
    
    # Run setup functions
    update_system
    install_essentials
    setup_user
    configure_ssh
    setup_security
    setup_cloudflared
    setup_monitoring
    
    print_message "info" "Base server setup completed successfully!"
    
    # Print next steps
    cat <<EOF

${GREEN}Next steps:${NC}
1. Log out and log back in as '${USERNAME}'.
2. Verify folder permissions for /opt/monitoring: 
   'ls -la /opt/monitoring'
3. Verify Cloudflared service status:
   'sudo systemctl status cloudflared'
4. Check the monitoring scripts in /opt/monitoring.
5. Review crontab entries:
   'crontab -l'

### Cloudflared Configuration:
- The Cloudflared configuration file is located at:
  '/etc/cloudflared/config.yml'.
- You can edit this file to update the tunnel's hostname or service settings if needed.
- Ensure the path to the credentials file is correct and the tunnel ID matches the one created for your server.
  To edit the config.yml, use:
  'sudo nano /etc/cloudflared/config.yml'

${YELLOW}Important:${NC}
- SSH is configured on port ${SSH_PORT}
- Root login is disabled
- UFW is enabled and configured
- Fail2ban is active
- Monitoring scripts are scheduled via cron
- All necessary folders and files are owned by ${USERNAME}

For any issues, check system logs and service statuses.
EOF
}

# Run main function
main "$@"
