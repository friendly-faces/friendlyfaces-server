#!/bin/bash

# Exit on any error
set -e

# Define color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script version
VERSION="1.0.0"

# Environment variables (with defaults)
USERNAME=${SERVER_USERNAME:-"defaultuser"}
SSH_PORT=${SSH_PORT:-22}
CLOUDFLARE_TOKEN=${CLOUDFLARE_TOKEN:-""}
MONITORING_REPO=${MONITORING_REPO:-"https://github.com/yourgithub/monitoring-scripts"}
SECURITY_SCRIPT=${SECURITY_SCRIPT:-"security-monitor.sh"}
SERVER_SCRIPT=${SERVER_SCRIPT:-"server-monitor.sh"}

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

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_message "error" "Please run this script as root or with sudo"
        exit 1
    fi
}

# Function to validate environment variables
validate_env() {
    if [ -z "$CLOUDFLARE_TOKEN" ]; then
        print_message "error" "CLOUDFLARE_TOKEN is not set"
        exit 1
    fi
    
    if [ "$USERNAME" = "defaultuser" ]; then
        print_message "warn" "Using default username. Set SERVER_USERNAME env variable to override."
    fi
}

# Function to set up new user
setup_user() {
    print_message "info" "Creating user: $USERNAME"
    adduser --gecos "" "$USERNAME" || return 1
    usermod -aG sudo "$USERNAME" || return 1
    print_message "info" "User $USERNAME created successfully"
}

# Function to set up SSH security
configure_ssh() {
    print_message "info" "Configuring SSH..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
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
    
    systemctl restart ssh
}

# Function to set up basic security
setup_security() {
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

[sshd]
enabled = true
port = ${SSH_PORT}
EOF
    
    systemctl enable fail2ban
    systemctl restart fail2ban
}

# Function to install and configure Cloudflared
setup_cloudflared() {
    print_message "info" "Installing Cloudflared..."
    
    # Install cloudflared
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared.deb
    rm cloudflared.deb
    
    # Create directory for cert
    mkdir -p /home/"$USERNAME"/.cloudflared
    chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"/.cloudflared
    
    print_message "warn" "Manual step required: Please run 'cloudflared login' as $USERNAME to authenticate"
    print_message "info" "After login, the cert.pem will be in /home/$USERNAME/.cloudflared/"
    
    # Install service with token
    read -p "Press enter after completing cloudflared login..."
    if [ ! -f "/home/$USERNAME/.cloudflared/cert.pem" ]; then
        print_message "error" "cert.pem not found. Please run cloudflared login first"
        exit 1
    fi
    
    cloudflared service install "$CLOUDFLARE_TOKEN"
    systemctl enable cloudflared
    systemctl start cloudflared
}

# Function to set up monitoring
setup_monitoring() {
    print_message "info" "Setting up monitoring scripts..."
    
    # Create monitoring directory
    mkdir -p /opt/monitoring
    cd /opt/monitoring
    
    # Download monitoring scripts
    curl -O "${MONITORING_REPO}/${SECURITY_SCRIPT}"
    curl -O "${MONITORING_REPO}/${SERVER_SCRIPT}"
    
    chmod +x "${SECURITY_SCRIPT}" "${SERVER_SCRIPT}"
    
    # Add cronjobs
    (crontab -l 2>/dev/null || true; echo "*/15 * * * * /opt/monitoring/${SECURITY_SCRIPT}") | crontab -
    (crontab -l 2>/dev/null || true; echo "*/5 * * * * /opt/monitoring/${SERVER_SCRIPT}") | crontab -
}

# Main function
main() {
    check_root
    validate_env
    
    print_message "info" "Starting server setup (v${VERSION})..."
    
    # Update system
    print_message "info" "Updating system packages..."
    apt update && apt upgrade -y
    
    # Install essential packages
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
    
    # Run setup functions
    setup_user
    configure_ssh
    setup_security
    setup_cloudflared
    setup_monitoring
    
    print_message "info" "Base server setup completed successfully!"
    
    # Print next steps
    cat <<EOF

${GREEN}Next steps:${NC}
1. Log out and log back in as '${USERNAME}'
2. Verify Cloudflared service status: 'systemctl status cloudflared'
3. Check monitoring scripts in /opt/monitoring
4. Review crontab entries: 'crontab -l'

${YELLOW}Important:${NC}
- SSH is configured on port ${SSH_PORT}
- Root login is disabled
- UFW is enabled and configured
- Fail2ban is active
- Monitoring scripts are scheduled via cron

For any issues, check system logs and service statuses.
EOF
}

# Run main function
main "$@"
