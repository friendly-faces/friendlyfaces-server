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
    if is_step_completed "user_setup"; then
        print_message "info" "User $USERNAME already exists, skipping user creation"
        return 0
    fi

    print_message "info" "Checking for user: $USERNAME"
    if id "$USERNAME" &>/dev/null; then
        print_message "info" "User $USERNAME already exists"
    else
        print_message "info" "Creating user: $USERNAME"
        adduser --gecos "" "$USERNAME" || return 1
    fi

    # Ensure user is in sudo group
    if ! groups "$USERNAME" | grep -q "\bsudo\b"; then
        usermod -aG sudo "$USERNAME" || return 1
    fi

    mark_step_complete "user_setup"
    print_message "info" "User setup completed"
}

# Function to set up SSH security
configure_ssh() {
    if is_step_completed "ssh_setup"; then
        print_message "info" "SSH already configured, skipping"
        return 0
    fi

    print_message "info" "Configuring SSH..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)
    
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
    mark_step_complete "ssh_setup"
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

[sshd]
enabled = true
port = ${SSH_PORT}
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
    
    # Check if cert.pem already exists
    if [ ! -f "/home/$USERNAME/.cloudflared/cert.pem" ]; then
        print_message "warn" "cert.pem not found. Please run 'cloudflared login' as $USERNAME"
        read -p "Have you completed cloudflared login? (y/n): " answer
        if [[ "$answer" != "y" ]]; then
            print_message "info" "Please complete the login step and run the script again"
            exit 0
        fi
    fi
    
    if [ ! -f "/home/$USERNAME/.cloudflared/cert.pem" ]; then
        print_message "error" "cert.pem still not found. Please run cloudflared login first"
        exit 1
    fi
    
    cloudflared service install "$CLOUDFLARE_TOKEN"
    systemctl enable cloudflared
    systemctl start cloudflared
    mark_step_complete "cloudflared_setup"
}

# Function to set up monitoring
setup_monitoring() {
    if is_step_completed "monitoring_setup"; then
        print_message "info" "Monitoring already configured, skipping"
        return 0
    fi

    print_message "info" "Setting up monitoring scripts..."
    
    # Create monitoring directory
    mkdir -p /opt/monitoring
    cd /opt/monitoring
    
    # Download monitoring scripts
    curl -O "${MONITORING_REPO}/${SECURITY_SCRIPT}"
    curl -O "${MONITORING_REPO}/${SERVER_SCRIPT}"
    
    chmod +x "${SECURITY_SCRIPT}" "${SERVER_SCRIPT}"
    
    # Add cronjobs (avoiding duplicates)
    (crontab -l 2>/dev/null | grep -v "${SECURITY_SCRIPT}"; echo "*/15 * * * * /opt/monitoring/${SECURITY_SCRIPT}") | sort -u | crontab -
    (crontab -l 2>/dev/null | grep -v "${SERVER_SCRIPT}"; echo "*/5 * * * * /opt/monitoring/${SERVER_SCRIPT}") | sort -u | crontab -
    
    mark_step_complete "monitoring_setup"
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
    validate_env
    
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
